#define WIN32_LEAN_AND_MEAN

#include <SDKDDKVer.h>
#include <windows.h>
#include "HookAPI.h"
#include <ws2tcpip.h>
#include <atomic>
#include <concurrent_queue.h>

#pragma comment (lib, "Ws2_32.lib")

#define BUFLEN 4096

std::atomic<SOCKET> client = NULL;
std::atomic<lua_State *> state = NULL;
std::atomic<bool> running = FALSE;
Concurrency::concurrent_queue<char *> queue;

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
	for (ptr = info; ptr != NULL; ptr = ptr->ai_next)
	{
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


DWORD WINAPI Main(LPVOID param)
{
	int length;
	char buffer[BUFLEN];
	char *ptr, *context;
	const char *separator = "\n\r";
	const char *command = "clientnotifyregister schandlerid=0 event=any\n";

	for (running = true; running; )
	{
		client = Connect("127.0.0.1", "25639");
		if (client == NULL) continue;

		for (int header = 182; header > 0; header -= length)
			length = recv(client, buffer, BUFLEN, 0);

		send(client, command, strlen(command), 0);
		recv(client, buffer, BUFLEN, 0);

		do
		{
			buffer[length = recv(client, buffer, BUFLEN, 0)] = 0;
			ptr = strtok_s(buffer, separator, &context);
			while (ptr != NULL)
			{
				int length = strlen(ptr) + 1;
				char *queued = new char[length];
				strcpy_s(queued, length, ptr);
				queue.push(queued);
				ptr = strtok_s(NULL, separator, &context);
			}

		} while (length > 0 && running);

		client = NULL;
		closesocket(client);
		WSACleanup();
	}

	return 0;
}

int SendCommand(lua_State *L)
{
	if (client == NULL || lua_type(L, 1) == -1) return 0;
	const char *buffer = lua_tostring(L, 1);
	send(client, buffer, strlen(buffer), 0);
	send(client, "\n", 1, 0);
	return 0;
}

void WINAPI OnRequire(lua_State *L, LPCSTR file, LPVOID param)
{
	if (strcmp(file, "lib/managers/chatmanager") == 0)
	{
		if (luaL_loadfile(L, "TeamSpeak/TeamSpeak.lua") == 0)
		{
			lua_pcall(L, 0, LUA_MULTRET, 0);

			lua_getglobal(L, "TeamSpeak");
			int index = lua_gettop(L);

			lua_pushcfunction(L, &SendCommand);
			lua_setfield(L, index, "Send");

			if (state == NULL)
			{
				state = L;
				CreateThread(NULL, 0, Main, NULL, 0, NULL);
			}
		}
	}
}

void WINAPI OnGameTick(lua_State *L, LPCSTR type, LPVOID param)
{
	if (L == state && strcmp(type, "update") == 0 && !queue.empty())
	{
		char *message;

		lua_getglobal(L, "TeamSpeak");
		int index = lua_gettop(L);

		while (queue.try_pop(message))
		{
			lua_getfield(L, index, "OnReceive");
			lua_pushlstring(L, message, strlen(message));
			lua_pcall(L, 1, 0, 0);
			delete[] message;
		}
	}
}

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
	switch (ul_reason_for_call)
	{
	case DLL_PROCESS_ATTACH:
		RegisterCallback(REQUIRE_CALLBACK, &OnRequire, NULL);
		RegisterCallback(GAMETICK_CALLBACK, &OnGameTick, NULL);
	case DLL_THREAD_ATTACH:
	case DLL_THREAD_DETACH:
		break;
	case DLL_PROCESS_DETACH:
		running = FALSE;
		break;
	}
	return TRUE;
}
