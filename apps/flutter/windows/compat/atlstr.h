#pragma once

#include <windows.h>
#include <string>
#include <vector>

// Compatibility header for environments where Microsoft Visual Studio C++ ATL
// is not installed. Provides the minimal conversion classes (CA2W, CW2A) and
// CString types expected by plugins such as flutter_secure_storage_windows.

class CA2W {
public:
    explicit CA2W(const char* psz) {
        if (!psz) {
            m_psz = nullptr;
            return;
        }
        int len = MultiByteToWideChar(CP_ACP, 0, psz, -1, nullptr, 0);
        if (len > 0) {
            m_buffer.resize(len);
            MultiByteToWideChar(CP_ACP, 0, psz, -1, &m_buffer[0], len);
            m_psz = m_buffer.data();
        } else {
            m_psz = const_cast<LPWSTR>(L"");
        }
    }

    operator LPCWSTR() const { return m_psz; }
    operator LPWSTR() const { return m_psz; }
    LPCWSTR operator*() const { return m_psz; }

    LPWSTR m_psz = nullptr;

private:
    std::vector<wchar_t> m_buffer;
};

class CW2A {
public:
    explicit CW2A(const wchar_t* psz) {
        if (!psz) {
            m_psz = nullptr;
            return;
        }
        int len = WideCharToMultiByte(CP_ACP, 0, psz, -1, nullptr, 0, nullptr, nullptr);
        if (len > 0) {
            m_buffer.resize(len);
            WideCharToMultiByte(CP_ACP, 0, psz, -1, &m_buffer[0], len, nullptr, nullptr);
            m_psz = m_buffer.data();
        } else {
            m_psz = const_cast<LPSTR>("");
        }
    }

    operator LPCSTR() const { return m_psz; }
    operator LPSTR() const { return m_psz; }
    LPCSTR operator*() const { return m_psz; }

    LPSTR m_psz = nullptr;

private:
    std::vector<char> m_buffer;
};

typedef std::wstring CStringW;
typedef std::string CStringA;
#ifdef UNICODE
typedef CStringW CString;
#else
typedef CStringA CString;
#endif
