***active win***
```
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
irm https://massgrave.dev/get | iex
```

***update repo***
```
bash <(curl -Ls https://raw.githubusercontent.com/DauDau432/App/refs/heads/main/repo.sh)
```
