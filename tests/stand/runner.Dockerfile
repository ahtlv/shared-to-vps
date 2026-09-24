# Подставной хост для стенда: бэкап и сторож на сервере работают с хоста, а
# на машине разработчика точка монтирования тома живёт внутри виртуалки
# докера и с хоста не видна. Контейнер с сокетом докера играет роль хоста.
# GNU-утилиты ставятся намеренно: на сервере будут они, а не busybox.
FROM alpine:3.20
RUN apk add --no-cache docker-cli docker-cli-compose python3 rclone age coreutils findutils tar gzip grep sed util-linux
