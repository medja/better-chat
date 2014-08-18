#include "stdafx.h"
#include <iostream>
#include "HookAPI.h"

#define WIN32_LEAN_AND_MEAN

#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdlib.h>
#include <stdio.h>

#pragma comment (lib, "Ws2_32.lib")
#pragma comment (lib, "Mswsock.lib")
#pragma comment (lib, "AdvApi32.lib")

#include <atomic>
#include <concurrent_queue.h>

#define BUFLEN 4096

SOCKET Connect(PCSTR hostname, PCSTR port)
{
	WSADATA wsaData;
	int result = WSAStartup(MAKEWORD(2, 2), &wsaData);
	if (result != 0) return NULL;

	struct addrinfo *info, *ptr, hints;
	ZeroMemory(&hints, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;
	result = getaddrinfo(hostname, port, &hints, &info);
	if (result != 0)
	{
		WSACleanup();
		return NULL;
	}

	SOCKET client = INVALID_SOCKET;
	for (ptr = info; ptr != NULL; ptr = ptr->ai_next) {
		client = socket(ptr->ai_family, ptr->ai_socktype, ptr->ai_protocol);
		if (client == INVALID_SOCKET)
		{
			WSACleanup();
			return NULL;
		}
		result = connect(client, ptr->ai_addr, (int)ptr->ai_addrlen);
		if (result == SOCKET_ERROR)
		{
			closesocket(client);
			client = INVALID_SOCKET;
			continue;
		}
		break;
	}

	freeaddrinfo(info);

	if (client == INVALID_SOCKET)
	{
		WSACleanup();
		return NULL;
	}

	char value = 1;
	setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &value, sizeof(value));

	return client;
}

HANDLE mutex = NULL;
std::atomic<SOCKET> client = NULL;
std::atomic<lua_State *> state = NULL;
std::atomic<bool> running = true;
Concurrency::concurrent_queue<char *> queue;

void SendCommand(const char *buffer)
{
	send(client, buffer, strlen(buffer), 0);
	send(client, "\n", 1, 0);
}

DWORD WINAPI Main(lua_State *L)
{
	int length;
	char buffer[BUFLEN];

	char *ptr, *context;
	const char *separator = "\n";

	const char *command = "clientnotifyregister schandlerid=0 event=any\n";

	while (running)
	{
		client = Connect("127.0.0.1", "25639");
		if (client == NULL) continue;

		for (int header = 182; header > 0; header -= length)
			length = recv(client, buffer, BUFLEN, 0);

		send(client, command, strlen(command), 0);
		recv(client, buffer, BUFLEN, 0);

		if (!queue.empty())
		{
			char *queued;
			while (queue.try_pop(queued))
			{
				SendCommand(queued);
				delete[] queued;
			}
		}

		do
		{
			buffer[length = recv(client, buffer, BUFLEN, 0)] = 0;

			WaitForSingleObject(mutex, INFINITE);
			L = state;

			ptr = strtok_s(buffer, separator, &context);
			while (ptr != NULL && strlen(ptr) > 2)
			{
				lua_getglobal(L, "TeamSpeak");
				lua_getfield(L, lua_gettop(L), "OnReceive");
				lua_pushlstring(L, ptr, strlen(ptr));
				lua_pcall(L, 1, 0, 0);
				ptr = strtok_s(NULL, separator, &context);
			}

			ReleaseMutex(mutex);
		} while (length > 0);

		client = NULL;
	}

	closesocket(client);
	WSACleanup();

	return 0;
}

int WriteToClient(lua_State *L)
{
	if (lua_type(L, 1) == -1) return 0;
	const char *buffer = lua_tostring(L, 1);
	if (client == NULL)
	{
		int length = strlen(buffer) + 1;
		char *queued = new char[length];
		strcpy_s(queued, length, buffer);
		queue.push(queued);
	}
	else SendCommand(buffer);
	return 0;
}

void WINAPI OnRequire(lua_State *L, LPCSTR file)
{
	if (strcmp(file, "lib/managers/chatmanager") == 0)
	{
		if (luaL_loadfile(L, "TeamSpeak/TeamSpeak.lua") == 0)
		{
			lua_pcall(L, 0, LUA_MULTRET, 0);

			lua_getglobal(L, "TeamSpeak");
			int index = lua_gettop(L);

			lua_pushcfunction(L, &WriteToClient);
			lua_setfield(L, index, "Send");

			if (state == NULL)
			{
				state = L;
				mutex = CreateMutex(NULL, FALSE, NULL);
				CreateThread(NULL, 0, Main, NULL, 0, NULL);
			}
		}
	}
}

void WINAPI OnGameTick(lua_State *L, LPCSTR type)
{
	if (L == state && strcmp(type, "update") == 0)
	{
		ReleaseMutex(mutex);
		WaitForSingleObject(mutex, INFINITE);
	}
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
	switch (ul_reason_for_call)
	{
	case DLL_PROCESS_ATTACH:
		RegisterCallback(REQUIRE_CALLBACK, &OnRequire);
		RegisterCallback(GAMETICK_CALLBACK, &OnGameTick);
		break;
	case DLL_THREAD_ATTACH:
	case DLL_THREAD_DETACH:
		break;
	case DLL_PROCESS_DETACH:
		if (state != NULL) CloseHandle(mutex);
		running = false;
		break;
	}
	return TRUE;
}

