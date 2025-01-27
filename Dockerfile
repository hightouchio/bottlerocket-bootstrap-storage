FROM alpine:3.21.2
RUN apk add --no-cache e2fsprogs bash parted mdadm lsblk blkid bash findmnt
COPY setup-runtime-storage.sh ./
RUN chmod +x ./setup-runtime-storage.sh
ENTRYPOINT ["/bin/bash", "./setup-runtime-storage.sh"]
