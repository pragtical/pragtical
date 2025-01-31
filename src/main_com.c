/*
 * Wrapper over pragtical.exe that when compiled as pragtical.com provides
 * console ready stdout/stderr for normal behavior on CMD or PowerShell.
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

/**
 * Get pragtical.exe absolute path relative to pragtical.com
 */
static void get_exe_filename(char *buf, int sz) {
    int len;
    wchar_t *buf_w = malloc(sizeof(wchar_t) * sz);
    if (buf_w) {
        len = GetModuleFileNameW(NULL, buf_w, sz - 1);
        buf_w[len] = L'\0';

        // Convert wide string to multi-byte (UTF-8)
        if (!WideCharToMultiByte(CP_UTF8, 0, buf_w, -1, buf, sz, NULL, NULL)) {
            buf[0] = '\0';
        } else {
            // Replace .com extension with .exe
            char *ext = strrchr(buf, '.');
            if (ext && strcmp(ext, ".com") == 0) {
                strcpy(ext, ".exe");
            }
        }

        free(buf_w);
    } else {
        buf[0] = '\0';
    }
}

/**
 * Attaches to the given command stdin, stdout, and stderr and redirects them to itself.
 */
void executeCommand(const char *command, DWORD *exit_code) {
    // Create pipes for stdin, stdout, and stderr
    HANDLE hStdInRead, hStdInWrite;
    HANDLE hStdOutRead, hStdOutWrite;
    HANDLE hStdErrRead, hStdErrWrite;

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE; // Allow child processes to inherit the handles
    sa.lpSecurityDescriptor = NULL;

    // Create pipe for stdin
    if (!CreatePipe(&hStdInRead, &hStdInWrite, &sa, 0)) {
        fprintf(stderr, "Error creating stdin pipe\n");
        return;
    }

    // Create pipe for stdout
    if (!CreatePipe(&hStdOutRead, &hStdOutWrite, &sa, 0)) {
        fprintf(stderr, "Error creating stdout pipe\n");
        return;
    }

    // Create pipe for stderr
    if (!CreatePipe(&hStdErrRead, &hStdErrWrite, &sa, 0)) {
        fprintf(stderr, "Error creating stderr pipe\n");
        return;
    }

    // Set the write end of the pipes to not be inherited
    SetHandleInformation(hStdInWrite, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hStdOutWrite, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(hStdErrWrite, HANDLE_FLAG_INHERIT, 0);

    // Prepare to create the process
    STARTUPINFO si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.hStdInput = hStdInRead;    // Redirect stdin
    si.hStdOutput = hStdOutWrite; // Redirect stdout
    si.hStdError = hStdErrWrite;  // Redirect stderr
    si.dwFlags |= STARTF_USESTDHANDLES;

    ZeroMemory(&pi, sizeof(pi));

    // Create the child process
    if (!CreateProcess(NULL, (LPSTR)command, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        fprintf(stderr, "Error creating process\n");
        return;
    }

    // Close unused ends of the pipes
    CloseHandle(hStdInRead);
    CloseHandle(hStdOutWrite);
    CloseHandle(hStdErrWrite);

    // Input and output handling loops
    char buffer[4096];
    DWORD bytesRead, bytesWritten;

    // Read input from the parent process and write to the child process
    while (true) {
        if (PeekNamedPipe(hStdInWrite, NULL, 0, NULL, &bytesRead, NULL) && bytesRead > 0) {
            if (ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer, sizeof(buffer) - 1, &bytesRead, NULL)) {
                WriteFile(hStdInWrite, buffer, bytesRead, &bytesWritten, NULL);
            }
        }

        // Read from stdout
        if (ReadFile(hStdOutRead, buffer, sizeof(buffer) - 1, &bytesRead, NULL) && bytesRead > 0) {
            buffer[bytesRead] = '\0'; // Null-terminate the string
            printf("%s", buffer);
        }

        // Read from stderr
        if (ReadFile(hStdErrRead, buffer, sizeof(buffer) - 1, &bytesRead, NULL) && bytesRead > 0) {
            buffer[bytesRead] = '\0'; // Null-terminate the string
            fprintf(stderr, "%s", buffer);
        }

        // Check if the process is still running
        DWORD waitResult = WaitForSingleObject(pi.hProcess, 0);
        if (waitResult == WAIT_OBJECT_0) {
            break; // Process has finished
        }

        Sleep(10); // Avoid busy waiting
    }

    // Get the exit code of the child process
    GetExitCodeProcess(pi.hProcess, exit_code);

    // Clean up handles
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    CloseHandle(hStdOutRead);
    CloseHandle(hStdErrRead);
    CloseHandle(hStdInWrite);
}

int main(int argc, char *argv[]) {
    // Allocate initial memory for the command
    size_t commandSize = 1024;
    char *command = (char *)malloc(commandSize);
    if (command == NULL) {
        fprintf(stderr, "Memory allocation failed\n");
        return 1;
    }

    // Start with the executable name
    char exename[2048];
    get_exe_filename(exename, sizeof(exename));
    snprintf(command, commandSize, "\"%s\"", exename);

    // Append command-line arguments
    for (int i = 1; i < argc; i++) {
        size_t argLength = strlen(argv[i]) + 3; // +3 for space and double quotes
        if (strlen(command) + argLength >= commandSize) {
            // Reallocate memory if needed
            commandSize *= 2; // Double the size
            command = (char *)realloc(command, commandSize);
            if (command == NULL) {
                fprintf(stderr, "Memory reallocation failed\n");
                return 1;
            }
        }
        strcat(command, " \"");
        strcat(command, argv[i]);
        strcat(command, "\"");
    }

    // Enable ANSI escape codes in Windows 10 and later
    OSVERSIONINFO osvi;
    osvi.dwOSVersionInfoSize = sizeof(OSVERSIONINFO);
    if (GetVersionEx(&osvi)) {
      if (osvi.dwMajorVersion >= 10) {
        HANDLE hConsole = GetStdHandle(STD_OUTPUT_HANDLE);
        DWORD mode;
        GetConsoleMode(hConsole, &mode);
        SetConsoleMode(hConsole, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
      }
    }

    SetEnvironmentVariable("PRAGTICAL_COM_WRAP", "1");

    // Execute the command and store the exit code
    DWORD exit_code = 0;
    executeCommand(command, &exit_code);

    // Free allocated memory
    free(command);

    return exit_code;
}
