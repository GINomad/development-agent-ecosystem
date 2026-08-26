# PS Excel Agent Pipeline Code Signing

Status: verified

Observed by: `knowledge_keeper`

Observed at: `2026-08-11T19:01:24.1674210Z`

Source revision: `ps-excel-agent` commit `dfb7b192df7721098334957fffade8aaa4a587d1`, completed PR `23464`, successful Azure build `205094`

## Verified pipeline behavior

The Windows pipeline in `azure-pipelines.yml`:

- imports the `CodeSigningKeyVaultSecrets` variable group;
- installs `AzureSignTool` version `7.0.1`;
- signs `planningspace.integration.excel.agent.dll` and `planningspace.integration.excel.agent.exe` from the .NET 10 build output with SHA-256 and DigiCert timestamping;
- validates both files with `Get-AuthenticodeSignature` and fails before archiving when either file is missing or does not have a `Valid` signature; and
- runs the signing and verification tasks on every branch because those tasks have no branch or pull-request condition.

Credential values are not repository knowledge. The pipeline references only the configured variable names; never copy secret values into source, task artifacts, logs, or managed knowledge.

## Evidence

- `C:/Repos/ps-excel-agent/azure-pipelines.yml` at `dfb7b192df7721098334957fffade8aaa4a587d1`, lines 1-15 and 108-160.
- Ledger agent result `043595e420cc4e629132f3b3aba11e8e`: exact-SHA build `205094` succeeded and PR `23464` completed.
- Ledger status event `fef6b549b5bf46b58f50e4a5b2b793ad`: build `205094` succeeded and the produced signatures were valid.

## Internet-delivered XLAM installation rule

Status: verified end-to-end for the cited exact commit and build

Observed by: direct Codex implementation outside the agent workflow

Observed at: 2026-08-14T21:32:53.5421196+03:00

Source revision: ps-excel-agent commit a2055ff722ceb9876c1fb2a44f3e621b554af9c6 on branch bugfix/ok/marcos-sign-installer-fix; successful Azure definition 814 build 205561

Excel xla/xlam files received from the Internet can be registered but loaded disabled when they retain Mark of the Web. Microsoft explicitly documents that a digital signature and trusted publisher do not override Mark of the Web for Excel add-ins. A released installer therefore must remove the Internet Zone marker from a verified local copy; signing alone is insufficient.

The release and installation contract is:

- sign and verify the final XLAM first;
- calculate its canonical post-sign SHA-256;
- replace exactly one installer placeholder with that SHA-256 before Authenticode-signing the installer;
- reject release staging if the placeholder is missing or duplicated;
- in the installer, verify the selected XLAM package structure and embedded release hash before filesystem or Excel registration mutation;
- copy to a private staging path, remove Zone.Identifier only from that verified staging copy, and recheck SHA-256;
- verify the installed hash and absence of Zone.Identifier before activating the Excel registration; and
- leave the downloaded source artifact and certificate stores unchanged.

The source-tree placeholder supports local development only. It must never remain in a published signed installer. Publisher trust, when required by corporate macro policy, is an endpoint-management responsibility and should distribute only the public publisher certificate through Intune or Group Policy; the product installer must not silently add a trusted publisher.

### Evidence

- C:/Repos/ps-excel-agent/ExcelAddIn/Install-ExcelAddIn.ps1 at a2055ff722ceb9876c1fb2a44f3e621b554af9c6, lines 11, 67-98, 289-322, and 355-369.
- C:/Repos/ps-excel-agent/azure-pipelines.yml at a2055ff722ceb9876c1fb2a44f3e621b554af9c6, lines 174-184 and 261-304.
- C:/Repos/ps-excel-agent/ExcelAddIn/tests/Install-ExcelAddIn.Tests.ps1 at a2055ff722ceb9876c1fb2a44f3e621b554af9c6, lines 44-69 and 135-221.
- Isolated NTFS regression on 2026-08-14 verified that ZoneId=3 remained on the downloaded source, was absent from the installed copy, SHA-256 remained E24550E894DAC18D0DA1EFB1D4AF4E599A5361549C12CB91D9AB5933AFB8E3B4, and a mismatched embedded hash failed before destination mutation.
- Validate-ExcelDeliverables.ps1 completed successfully for Main-bck.xlsm, Main.xlsx, and PlanningSpaceExcelAddIn.xlam on 2026-08-14.
- Azure definition 814 build 205561 completed successfully for exact sourceVersion a2055ff722ceb9876c1fb2a44f3e621b554af9c6 on 2026-08-14: https://dev.azure.com/Aucerna/PlanningSpace/_build/results?buildId=205561&view=results
- The user confirmed after build 205561 that the delivered installation works.
- Microsoft: https://learn.microsoft.com/en-us/microsoft-365-apps/security/internet-macros-blocked
- Microsoft: https://learn.microsoft.com/en-us/microsoft-365-apps/security/trusted-publisher

This verification applies only to the cited exact commit and build. Future releases must repeat the hash binding, signing, installer tests, hosted pipeline gates, and downloaded-artifact validation before they inherit verified status.
