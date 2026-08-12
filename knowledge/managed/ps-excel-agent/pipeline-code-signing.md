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
