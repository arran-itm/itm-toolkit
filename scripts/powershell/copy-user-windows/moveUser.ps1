robocopy "C:\Users\$User" "E:\Users\$User" /E /COPY:DAT /R:2 /W:2 /XJ /MT:8 /XD "C:\Users\$User\AppData" "C:\Users\$User\OneDrive*" /TEE /LOG:E:\backup-logs\$User.txt
