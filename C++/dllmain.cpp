#define WIN32_LEAN_AND_MEAN

#include <SDKDDKVer.h>
#include <windows.h>
#include "HookAPI.h"
#include "TeamSpeak.h"
#include <ws2tcpip.h>
#include <atomic>
#include <list>
#include <concurrent_queue.h>

#pragma comment (lib, "Ws2_32.lib")

// Default buffer length
#define BUFLEN 4096

// Socket used for TeamSpeak communication
std::atomic<SOCKET> client = NULL;
// Lua state used when requiring script files
std::atomic<lua_State *> state = NULL;
// Boolean telling the socket thread whether to keep the network loop running
std::atomic<bool> running = FALSE;
// Queue of commands to be sent to the Lua script
Concurrency::concurrent_queue<String *> queue;
// Chat message history and its length and status
std::list<ChatMessage *> history;
unsigned int max_history = 20;
bool loading_history = false;

// Tries to connect to TeamSpeak using ClientQuery
// Returns a new socket or NULL on failure

SOCKET Connect(PCSTR hostname, PCSTR port)
{
	// Creates a structure used for containing the socket information
	WSADATA wsaData;
	int result = WSAStartup(MAKEWORD(2, 2), &wsaData);
	if (result != 0) return NULL;

	// Creates a structure used for containing the connection information
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

	// Tries to connect to the specified address
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

	// Releases the address information strcuture from memory
	freeaddrinfo(info);

	// Return NULL if the connection could not be established
	if (client == INVALID_SOCKET)
	{
		WSACleanup();
		return NULL;
	}

	// Sets keep alive to true for the socket
	char value = 1;
	setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &value, sizeof(value));

	return client;
}

// Socket thread
// Executes a loop reading messages and passing them to the Lua script

DWORD WINAPI Main(LPVOID param)
{
	int length;
	char buffer[BUFLEN];
	char *ptr, *context;
	const char *separator = "\n\r";
	const char *command = "clientnotifyregister schandlerid=0 event=any\n";

	// Starts the network loop
	for (running = true; running;)
	{
		// Connects to the local TeamSpeak ClientQuery and retries on failure
		client = Connect("127.0.0.1", "25639");
		if (client == NULL) continue;

		// Receives the initial ClientQuery headers
		for (int header = 182; header > 0; header -= length)
			length = recv(client, buffer, BUFLEN, 0);

		// Sends a "listen to all events" command and receives its response
		send(client, command, strlen(command), 0);
		recv(client, buffer, BUFLEN, 0);

		// Reads messages from the ClientQuery input stream
		do
		{
			// Receives a message and null terminates it
			buffer[length = recv(client, buffer, BUFLEN, 0)] = 0;
			// Splits up different messages that might be in the same buffer
			ptr = strtok_s(buffer, separator, &context);
			while (ptr != NULL)
			{
				// Copies the messages to heap memory and saves them to a queue
				queue.push(new String(ptr));
				ptr = strtok_s(NULL, separator, &context);
			}

		} while (length > 0 && running);

		// Once the connection is closed cleans up all of its resources
		{
			SOCKET socket = client;
			client = NULL;
			closesocket(socket);
			WSACleanup();
		}
	}

	return 0;
}

// Called by the Lua script when a TeamSpeak command is used
// Sends a message using the ClientQuery socket

int SendCommand(lua_State *L)
{
	// Stops if the socket is not connected or no message has been sent
	if (client == NULL || lua_type(L, 1) == -1) return 0;

	// Reads the message and sends it
	const char *buffer = lua_tostring(L, 1);
	send(client, buffer, strlen(buffer), 0);
	send(client, "\n", 1, 0);
	return 0;
}

// Called by the Lua script when a new message is received
// Saves a message to chat history

int SaveChatMessage(lua_State *L)
{
	// Stops if chat history is disabled or being loaded
	if (loading_history || max_history < 1) return 0;

	// Creates a new message
	ChatMessage *message = new ChatMessage();
	message->sender = String(lua_tostring(L, 1));
	message->message = String(lua_tostring(L, 2));
	// Saves the Color userdata directly
	message->color = *(Color *)lua_touserdata(L, 3);
	message->icon = String(lua_tostring(L, 4));

	// Inserts the message at the end of the chat history
	history.push_back(message);
	// Removes the first few messages if the limit has been reached
	while (history.size() > max_history)
	{
		delete history.front();
		history.pop_front();
	}

	return 0;
}

// Called by the Lua script once the chat GUI loads
// Loads all messages from chat histor into the game

int LoadChatMessages(lua_State *L)
{
	// Stops if there is no chat history
	if (max_history < 1 || history.empty()) return 0;
	loading_history = true;

	// Indexes the global TeamSpeak variable
	ChatMessage *message;
	lua_getglobal(L, "TeamSpeak");
	int index = lua_gettop(L);
	
	// And loads each message inside the chat history
	for (auto i = history.begin(); i != history.end(); i++)
	{
		message = *i;
		lua_getfield(L, index, "ShowMessage");
		lua_pushlstring(L, message->sender.value(), message->sender.length());
		lua_pushlstring(L, message->message.value(), message->message.length());
		// Recreates and pushes the userdata
		message->color.push(L);
		// Sets an icon if required
		if (message->icon.value() == NULL) lua_pushnil(L);
		else lua_pushlstring(L, message->icon.value(), message->icon.length());
		lua_pcall(L, 4, 0, 0);
	}

	loading_history = false;
	return 0;
}

// Requires the TeamSpeak Lua script and loads it into the game

void WINAPI OnRequire(lua_State *L, LPCSTR file, LPVOID param)
{
	// If the required file matches any we need to override
	if (strcmp(file, "lib/managers/chatmanager") == 0)
	{
		// Load that file into the game
		if (luaL_loadfile(L, "TeamSpeak/TeamSpeak.lua") == 0)
		{
			// And execute it
			lua_pcall(L, 0, LUA_MULTRET, 0);

			// Indexes the global TeamSpeak variable
			lua_getglobal(L, "TeamSpeak");
			int index = lua_gettop(L);

			// Check the chat history option
			lua_getfield(L, index, "Options");
			lua_getfield(L, -1, "ChatHistory");
			max_history = (unsigned int)lua_tonumber(L, -1);

			// Maps C++ functions to Lua variables inside the TeamSpeak object
			lua_pushcfunction(L, &SendCommand);
			lua_setfield(L, index, "Send");
			lua_pushcfunction(L, &SaveChatMessage);
			lua_setfield(L, index, "SaveChatMessage");
			lua_pushcfunction(L, &LoadChatMessages);
			lua_setfield(L, index, "LoadChatMessages");

			// Register a Lua hook if chat history is enabled
			if (max_history > 0)
			{
				lua_getfield(L, index, "Hooks");
				lua_getfield(L, -1, "Add");
				lua_pushvalue(L, -2);
				lua_pushstring(L, "ChatManagerOnLoad");
				lua_pushcfunction(L, LoadChatMessages);
				lua_pcall(L, 3, 0, 0);
			}
			
			// Saves the current Lua state and creates the network thread 
			state = L;
			if (!running) CreateThread(NULL, 0, Main, NULL, 0, NULL);
		}
	}
}

// Runs on game ticks and sends messages from TeamSpeak to the Lua script

void WINAPI OnGameTick(lua_State *L, LPCSTR type, LPVOID param)
{
	// If the Lua state matches out initial script load state,
	// the tick type is an update tick and out message queue is not empty
	if (L == state && strcmp(type, "update") == 0 && !queue.empty())
	{
		// Indexes the global TeamSpeak variable
		lua_getglobal(L, "TeamSpeak");
		int index = lua_gettop(L);

		// And sends each message over to a Lua function
		for (String *message; queue.try_pop(message);)
		{
			lua_getfield(L, index, "OnReceive");
			lua_pushlstring(L, message->value(), message->length());
			lua_pcall(L, 1, 0, 0);
			delete message;
		}
	}
}

// DLL entry point

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
	switch (ul_reason_for_call)
	{
	case DLL_PROCESS_ATTACH:
		// Registers a callback for when the game requires an internal file
		RegisterCallback(REQUIRE_CALLBACK, &OnRequire, NULL);
		// Registers a callback for game ticks
		RegisterCallback(GAMETICK_CALLBACK, &OnGameTick, NULL);
	case DLL_THREAD_ATTACH:
	case DLL_THREAD_DETACH:
		break;
	case DLL_PROCESS_DETACH:
		// Stops the network loop
		running = FALSE;
		break;
	}
	return TRUE;
}
