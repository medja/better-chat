#pragma once

// Simple managed string class

class String
{
private:
	// Length and content of the string
	int length_;
	char *value_;
public:
	// Default constructor for a NULL string
	String()
	{
		length_ = 0;
		value_ = NULL;
	}

	// String constructor copies the value to heap memory
	String(const char *pointer)
	{
		if (pointer == NULL)
		{
			length_ = 0;
			value_ = NULL;
		}
		else
		{
			length_ = strlen(pointer);
			value_ = new char[length_ + 1];
			strcpy_s(value_, length_ + 1, pointer);
		}
	}

	// Copying a string will destruct the original
	String& operator=(String& other)
	{
		this->~String();
		length_ = other.length_;
		value_ = other.value_;
		// Prevent the destructor deleing a string twice
		other.length_ = 0;
		other.value_ = NULL;
		return *this;
	}

	const bool String::operator==(const String &other)
	{
		if (this->value_ == NULL) return other.value_ == NULL;
		if (other.value_ == NULL) return false;
		return strcmp(this->value_, other.value_) == 0;
	}

	const bool String::operator!=(const String &other)
	{
		return !(*this == other);
	}

	// Deletes a string's content if its not null
	~String() { if (value_ != NULL) delete[] value_; }

	// Getters for the value and length of the string
	const char *value() { return value_; }
	const int length() { return length_; }
};

// In-game Color class representation

struct Color
{
	// Color values ordered as they are in-game
	float r, g, b, a;

	// Calls the Color class constructor in Lua
	// The result will get pushed to the top of the stack
	int push(lua_State *L)
	{
		lua_getglobal(L, "Color");
		lua_pushfloat(L, a);
		lua_pushfloat(L, r);
		lua_pushfloat(L, g);
		lua_pushfloat(L, b);
		return lua_pcall(L, 4, 1, 0);
	}
};

// In-game chat message representation

struct ChatMessage
{
	String sender, message, icon;
	Color color;
};