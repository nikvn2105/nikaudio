#pragma once
#include <windns.h>
#include <memory>

// Advertisements live for the process lifetime. DNSAPI removes them on exit.
inline void publishBonjour(uint16_t port, const wchar_t* service) {
    struct Registration {
        std::wstring name, host;
        DNS_SERVICE_REGISTER_REQUEST request{};
        DNS_SERVICE_CANCEL cancel{};
    };
    wchar_t hostname[MAX_COMPUTERNAME_LENGTH + 1]{};
    DWORD size = static_cast<DWORD>(std::size(hostname));
    if (!GetComputerNameW(hostname, &size)) return;

    auto registration = std::make_unique<Registration>();
    registration->name = L"NiKAudio " + std::wstring(hostname) + L"." + service + L".local";
    registration->host = std::wstring(hostname) + L".local";
    auto& request = registration->request;
    request.Version = DNS_QUERY_REQUEST_VERSION1;
    request.pServiceInstance = DnsServiceConstructInstance(registration->name.c_str(), registration->host.c_str(),
                                                           nullptr, nullptr, port, 0, 0, 0, nullptr, nullptr);
    if (!request.pServiceInstance) return;
    request.pRegisterCompletionCallback = [](DWORD, void*, PDNS_SERVICE_INSTANCE result) {
        if (result) DnsServiceFreeInstance(result);
    };
    const DWORD result = DnsServiceRegister(&request, &registration->cancel);
    if (result == ERROR_SUCCESS || result == DNS_REQUEST_PENDING) {
        // Keep the async request and its inputs valid until the process exits.
        static_cast<void>(registration.release());
    } else {
        DnsServiceFreeInstance(request.pServiceInstance);
    }
}
