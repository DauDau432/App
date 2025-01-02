```
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
irm https://massgrave.dev/get | iex
```
```
DISM /Online /Set-Edition:Enterprise /ProductKey:W269N-WFGWX-YVC9B-4J6C9-T83GX /AcceptEula

```

```
slmgr /ato
```
```
slmgr /xpr
```
