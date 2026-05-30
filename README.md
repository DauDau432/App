***active win***
```
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```
```
irm https://massgrave.dev/get | iex
```

***update repo***
```
bash <(curl -Ls https://h2cloud.vn/repo/repo.sh)
```

***check os***
```
bash <(curl -Ls https://raw.githubusercontent.com/DauDau432/App/refs/heads/main/os.sh)
```

***mở giới hạn hệ thống***
```
bash <(curl -Ls https://raw.githubusercontent.com/DauDau432/App/refs/heads/main/ulimit_max_tuner.sh)
```

***quản lý all firewall***
```
bash <(curl -Ls https://raw.githubusercontent.com/DauDau432/App/refs/heads/main/firewall_manager.sh)
```

***thống kê kết nối trên vps***
```
wget -qO monitor.py https://raw.githubusercontent.com/DauDau432/App/refs/heads/main/monitor.py && python3 monitor.py
```

***thống kê tài nguyên vps***
```
bash <(curl -Ls https://raw.githubusercontent.com/DauDau432/App/refs/heads/main/sys_monitor.sh)
```

***thống kê tài nguyên virtualizor***
```
bash <(curl -Ls https://raw.githubusercontent.com/DauDau432/App/refs/heads/main/virtualizor.sh)
```

• hỗ trợ ưu tiên sort theo thứ tự flag:

  • --cpu

  • --ram
  
  • --disk
  
  • --upload
  
  • --download

• có --top N để đổi số lượng VPS hiển thị
