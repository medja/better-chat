#define WIN32_LEAN_AND_MEAN

#include <SDKDDKVer.h>
#include <windows.h>
#include "HookAPI.h"
#include "BetterChat.h"
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
std::atomic<bool> running = false;
// Boolean telling if the TeamSpeak connection has been initialized in Lua
std::atomic<bool> initialized = true;
// Queue of commands to be sent to the Lua script
Concurrency::concurrent_queue<String *> queue;
// Chat message history, its length and status
std::list<ChatMessage *> history;
unsigned int max_history = 20;
bool loading_history = false;
// Id of last client to send a private message
String last_sender;
// Text and cursor position of the chat input box
String input_text;
float input_position;

// Tries to connect to TeamSpeak using ClientQuery
// Returns a new socket or NULL on failure

SOCKET Connect(PCSTR hostname, PCSTR port)
{
	// Create a structure used for containing the socket information
	WSADATA wsaData;
	int result = WSAStartup(MAKEWORD(2, 2), &wsaData);
	if (result != 0) return NULL;

	// Create a structure used for containing the connection information
	struct addrinfo *info, *ptr, hints;
	ZeroMemory(&hints, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;
	result = getaddrinfo(hostname, port, &hints, &info);
	// Cleanup on failure
	if (result != 0)
	{
		WSACleanup();
		return NULL;
	}

	// Try to connect to the specified address
	SOCKET client = INVALID_SOCKET;
	for (ptr = info; ptr != NULL; ptr = ptr->ai_next)
	{
		client = socket(ptr->ai_family, ptr->ai_socktype, ptr->ai_protocol);
		// Cleanup and stop on failure
		if (client == INVALID_SOCKET)
		{
			WSACleanup();
			return NULL;
		}
		result = connect(client, ptr->ai_addr, (int)ptr->ai_addrlen);
		// Cleanup but try to continue on failure
		if (result == SOCKET_ERROR)
		{
			closesocket(client);
			client = INVALID_SOCKET;
			continue;
		}
		break;
	}

	// Release the address information strcuture from memory
	freeaddrinfo(info);

	// Return NULL if the connection could not be established
	if (client == INVALID_SOCKET)
	{
		WSACleanup();
		return NULL;
	}

	// Set keep alive to true for the socket
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

	// Start the network loop
	for (running = true; running;)
	{
		// Connect to the local TeamSpeak ClientQuery and retry on failure
		client = Connect("127.0.0.1", "25639");
		if (client == NULL) continue;

		// Receive the initial ClientQuery headers
		for (int header = 182; header > 0; header -= length)
			length = recv(client, buffer, BUFLEN, 0);

		// Send a "listen to all events" command and receive its response
		send(client, command, strlen(command), 0);
		recv(client, buffer, BUFLEN, 0);

		// Read messages from the ClientQuery input stream
		do
		{
			// Receive a message and null terminate it
			buffer[length = recv(client, buffer, BUFLEN, 0)] = 0;
			// Split up different messages that might be in the same buffer
			ptr = strtok_s(buffer, separator, &context);
			while (ptr != NULL)
			{
				// Copy the messages to heap memory and save them to a queue
				queue.push(new String(ptr));
				ptr = strtok_s(NULL, separator, &context);
			}

		} while (length > 0 && running);

		// Once the connection is closed clean up all of its resources
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
	// Stop if the socket is not connected or no message has been sent
	if (client == NULL || lua_type(L, 1) == LUA_TNONE) return 0;

	// Send the message
	const char *buffer = lua_tostring(L, 1);
	send(client, buffer, strlen(buffer), 0);
	send(client, "\n", 1, 0);
	return 0;
}

// Called by the Lua script when a new message is received
// Saves a message to chat history

int SaveChatMessage(lua_State *L)
{
	// Stop if chat history is disabled or being loaded
	if (loading_history || max_history < 1) return 0;

	// Create a new message
	ChatMessage *message = new ChatMessage();
	message->sender = String(lua_tostring(L, 1));
	message->message = String(lua_tostring(L, 2));
	// Save the Color userdata directly
	message->color = *(Color *)lua_touserdata(L, 3);
	message->icon = String(lua_tostring(L, 4));

	// Insert the message at the end of the chat history
	history.push_back(message);
	// Remove the first few messages if the limit has been reached
	while (history.size() > max_history)
	{
		delete history.front();
		history.pop_front();
	}

	return 0;
}

// Called by the Lua script once the chat gui loads
// Loads all messages from chat histor into the chat

int LoadChatMessages(lua_State *L)
{
	// Stop if there is no chat history or we didn't recive a chat gui
	if (history.empty() || lua_type(L, 1) == LUA_TNONE) return 0;
	loading_history = true;

	// Stores the current message
	ChatMessage *message;
	bool is_private;

	// Get the private message color
	lua_getglobal(L, "BC");
	lua_getfield(L, -1, "Options");
	lua_getfield(L, -1, "colors");
	lua_getfield(L, -1, "private");
	int private_color = lua_gettop(L);

	// Get the BetterChat message formatters
	lua_getfield(L, -4, "Formatters");

	// And load each message inside the chat history
	for (auto i = history.begin(); i != history.end(); i++)
	{
		message = *i;
		lua_getfield(L, 1, "receive_message");
		lua_pushvalue(L, 1);
		lua_pushlstring(L, message->sender.value(), message->sender.length());
		lua_pushlstring(L, message->message.value(), message->message.length());
		// Recreate and push the userdata
		message->color.push(L);
		// Check if this is a private message
		is_private = lua_equal(L, -1, private_color) == 1;
		// Set an icon if required
		if (message->icon.value() == NULL) lua_pushnil(L);
		else lua_pushlstring(L, message->icon.value(), message->icon.length());
		lua_pcall(L, 5, 0, 0);

		// Format the last message if required
		if (is_private)
		{
			// Call the private formatter
			lua_getfield(L, -1, "private");
			lua_pushvalue(L, 1);
			lua_pcall(L, 1, 0, 0);
		}
	}

	loading_history = false;
	return 0;
}

// Requires the BetterChat Lua script and loads it into the game

void WINAPI OnRequire(lua_State *L, LPCSTR file, LPVOID param)
{
	// If the required file matches any we need to override
	if (strcmp(file, "lib/managers/chatmanager") == 0
	 || strcmp(file, "lib/managers/hud/hudchat") == 0
	 || strcmp(file, "lib/utils/game_state_machine/gamestatemachine") == 0)
	{
		// Check if the global BetterChat variable has been defined
		lua_getglobal(L, "BC");
		int type = lua_type(L, -1);

		// Load the main script for the required file
		if (luaL_loadfile(L, "BetterChat/BetterChat.lua") == 0)
		{
			// And execute it
			lua_pcall(L, 0, LUA_MULTRET, 0);

			// Make sure to only initalize once for each state
			if (type != LUA_TNIL) return;

			// Index the global BetterChat variable
			lua_getglobal(L, "BC");
			int index = lua_gettop(L);

			// Load Lua variables
			if (last_sender != NULL)
			{
				lua_pushlstring(L, last_sender.value(), last_sender.length());
				lua_setfield(L, index, "last_sender");
			}
			if (input_text != NULL)
			{
				lua_createtable(L, 0, 2);
				lua_pushlstring(L, input_text.value(), input_text.length());
				lua_setfield(L, -2, "text");
				lua_pushfloat(L, input_position);
				lua_setfield(L, -2, "position");
				lua_setfield(L, index, "input");
			}

			// Check the chat history option
			lua_getfield(L, index, "Options");
			lua_getfield(L, -1, "chat_history");
			max_history = (unsigned int)lua_tonumber(L, -1);

			// Map C++ functions in Lua
			lua_pushcfunction(L, &SendCommand);
			lua_setfield(L, index, "send_command");
			lua_pushcfunction(L, &SaveChatMessage);
			lua_setfield(L, index, "save_chat_message");

			// Register a Lua hook for loading messages if chat history is enabled
			if (max_history > 0)
			{
				lua_getfield(L, index, "Hooks");
				lua_getfield(L, -1, "add");
				lua_pushvalue(L, -2);
				lua_pushstring(L, "ChatGUI:Load");
				lua_pushcfunction(L, &LoadChatMessages);
				lua_pcall(L, 3, 0, 0);
			}

			// Note that the Lua side of this mod still requires initialization
			initialized = false;
			
			// Save the current Lua state and create the network thread
			state = L;
			if (!running) CreateThread(NULL, 0, Main, NULL, 0, NULL);
		}
	}
}

// Runs on game ticks and sends messages from BetterChat to the Lua script

void WINAPI OnGameTick(lua_State *L, LPCSTR type, LPVOID param)
{
	// Make sure this is the correct Lua state
	if (L != state) return;

	if (strcmp(type, "update") == 0)
	{
		// Index the global BetterChat variable
		lua_getglobal(L, "BC");
		int index = lua_gettop(L);

		// Initialize the Lua part of the mod if a connection
		// to ClientQuery has been established
		if (!initialized && client != NULL)
		{
			initialized = true;
			// Update the list of clients connected to the server
			lua_getfield(L, index, "fetch_info");
			lua_pcall(L, 0, 0, 0);
		}

		// Pass any recived messages from TeamSpeak to Lua
		if (!queue.empty())
		{
			lua_getfield(L, index, "Hooks");
			for (String *message; queue.try_pop(message);)
			{
				lua_getfield(L, -1, "call");
				lua_pushvalue(L, -2);
				lua_pushstring(L, "TeamSpeak:Receive");
				lua_pushlstring(L, message->value(), message->length());
				lua_pcall(L, 3, 0, 0);
				delete message;
			}
		}
	}
	else if (strcmp(type, "destroy") == 0)
	{
		// Index the global BetterChat variable
		lua_getglobal(L, "BC");
		int index = lua_gettop(L);

		// Store Lua variables
		lua_getfield(L, index, "last_sender");
		if (lua_type(L, -1) != LUA_TNIL) last_sender = String(lua_tostring(L, -1));
		lua_getfield(L, index, "input");
		if (lua_type(L, -1) != LUA_TNIL)
		{
			lua_getfield(L, -1, "text");
			input_text = String(lua_tostring(L, -1));
			lua_getfield(L, -2, "position");
			input_position = lua_tonumber(L, -1);
		}
	}
}

// DLL entry point

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
	switch (ul_reason_for_call)
	{
	case DLL_PROCESS_ATTACH:
		// Register a callback for when the game requires an internal file
		RegisterCallback(REQUIRE_CALLBACK, &OnRequire, NULL);
		// Register a callback for game ticks
		RegisterCallback(GAMETICK_CALLBACK, &OnGameTick, NULL);
		break;
	case DLL_THREAD_ATTACH:
	case DLL_THREAD_DETACH:
		break;
	case DLL_PROCESS_DETACH:
		// Stop the network loop
		running = false;
		// Free memory
		for (String *message; !queue.empty();) if (queue.try_pop(message)) delete message;
		for (; !history.empty(); history.pop_front()) delete history.front();
		break;
	}
	return TRUE;
}
