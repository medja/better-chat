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

	// Deletes a string's content if its not null
	~String() { if (value_ != NULL) delete[] value_; }

	// Getters for the value and length of the string
	const char *value() { return value_; }
	const int length() { return length_; }
};