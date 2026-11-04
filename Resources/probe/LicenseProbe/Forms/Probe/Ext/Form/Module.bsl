// SPDX-License-Identifier: MIT
&AtClient
Procedure OnOpen(Cancel)
    Receipt = New Structure;
    Receipt.Insert("source", "platform-license-monitoring");
    Receipt.Insert("connectionString", InfoBaseConnectionString());
    Receipt.Insert("completed", False);
    Licenses = New Array;
    Receipt.Insert("licenses", Licenses);
    Try
        Search = New LicenseMonitoringLicenseManagerSearchParameters;
        Addresses = New Array;
        Addresses.Add("127.0.0.1:15441");
        Search.LicenseManagerAddresses = Addresses;
        Search.LicenseManagerLookupPorts = New Array;
        Managers = LicenseMonitoring.GetLicenseManagers(Search, 2);
        For Each License In LicenseMonitoring.GetBusyLicenses(Managers) Do
            Product = License.Product;
            Manager = Product.LicenseManager;
            For Each Recipient In License.LicenseRecipients Do
                // Do not export identities or connections of other clients.
                If Recipient.InfoBaseConnectionString = Receipt.connectionString Then
                    Item = New Structure;
                    Item.Insert("connectionString", Recipient.InfoBaseConnectionString);
                    Item.Insert("processID", Recipient.ProcessID);
                    Item.Insert("hardware", Product.LicenseType = LicenseMonitoringLicenseType.Hardware);
                    Item.Insert("managerAddress", Manager.ComputerAddress);
                    Item.Insert("managerPort", Manager.Port);
                    Item.Insert("managerID", Manager.ID);
                    Licenses.Add(Item);
                EndIf;
            EndDo;
        EndDo;
        Receipt.completed = True;
    Except
        // Unsupported monitoring or an unavailable manager is not a license refusal.
        Receipt.Insert("observation", "unavailable");
    EndTry;
    Writer = New JSONWriter;
    Writer.OpenFile(LaunchParameter, "UTF-8", False);
    WriteJSON(Writer, Receipt);
    Writer.Close();
    Exit(False);
EndProcedure
