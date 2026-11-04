# Client license receipt

`LicenseProbe.xml` is an external processor in the platform XML format. Build it
with `DESIGNER /LoadExternalDataProcessorOrReportFromFiles` (no base is needed),
then run `ENTERPRISE /RunModeManagedApplication /Execute <probe.epf> /C <receipt.json>`
in the disposable probe base. The application owns the unique base and receipt directory.

The managed form queries only `127.0.0.1:15441`, with broadcast discovery disabled.
It exports only recipients whose connection string equals its own connection.
The host additionally requires its launched client PID, the exact private file
base, a hardware license and the KeyBridge manager address and port. Process
success and unchanged VM/key/client context remain separate host checks. No new
issuance is required: the API describes held licenses, including reuse.

The API is documented starting with 1C 8.5.4. Unsupported monitoring, incomplete
recipient information or a different primary recipient PID cannot confirm the
source. The receipt deliberately excludes license numbers, users and other bases.

API provenance: the installed vendor syntax help, version **8.5.4.1878**, opened
through `unica.docs` (`source: platform-help`):

- `platform-syntax-help:syntax-context:objects/catalog63/catalog3082/LicenseMonitoringManager/methods/GetLicenseManagers6721.html`
- `platform-syntax-help:syntax-context:objects/catalog63/catalog3082/LicenseMonitoringManager/methods/GetBusyLicenses6723.html`
- `platform-syntax-help:syntax-context:objects/catalog63/catalog3082/LicenseMonitoringLicenseManagerSearchParameters/properties/LicenseManagerAddresses14315.html`
- `platform-syntax-help:syntax-context:objects/catalog63/catalog3082/LicenseMonitoringLicenseManagerSearchParameters/properties/LicenseManagerLookupPorts14314.html`
- `platform-syntax-help:syntax-context:objects/catalog63/catalog3082/LicenseMonitoringLicenseRecipient/properties/InfoBaseConnectionString14274.html`
- `platform-syntax-help:syntax-context:objects/catalog63/catalog3082/LicenseMonitoringLicenseRecipient/properties/ProcessID14271.html`
- `platform-syntax-help:syntax-context:objects/catalog63/catalog3082/LicenseMonitoringInstalledProduct/properties/LicenseType14288.html`
- `platform-syntax-help:syntax-context:objects/catalog63/catalog3082/LicenseMonitoringLicenseManager/properties/ComputerAddress14310.html`
- `platform-syntax-help:platform-guides:zif3_LoadExternalDataProcessorOrReportFromFiles`
- `platform-syntax-help:platform-guides:zif2_execute`

The XML descriptor and managed form structure follow the platform 8.3.27 external
artifact fixture in Unica. Static XML and host receipt tests do not establish that
the installed client and guest manager return complete recipient information;
that requires a run with the actual hardware key.

Native compilation and execution require an available 1C license. Source admission,
XML parsing and receipt tests do not substitute for that check.
