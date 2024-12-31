@echo off
echo Dang reset thoi gian dung thu Windows...
slmgr /rearm
echo Dang khoi dong lai dich vu bao ve phan mem de ap dung thay doi...
net stop sppsvc
net start sppsvc
echo Reset thoi gian dung thu thanh cong ma khong can khoi dong lai.
pause
