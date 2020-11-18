#!/bin/bash
#
# Automate Raspberry Pi Backups
#
# Kristofer Källsbo 2017 www.hackviking.com
#
# Usage: system_backup.sh {path} {days of retention}
#
# Below you can set the default values if no command line args are sent.
# The script will name the backup files {$HOSTNAME}.{YYYYmmdd}.img
# When the script deletes backups older then the specified retention
# it will only delete files with it's own $HOSTNAME.
#

# Declare vars and set standard values
#backup_path=/media/USBHDD1/backups
backup_path=/media/USBFLASH1/backups
# for Nearline minimal storage term is 30 days, so retention should not be less than 7 days for 4 kept versions set in lifeycle rule (as 7*4 < 30)
# however this goes to cron schedule only
retention_days=5
backup_bucket=gs://raspi-backup-main
storage_class="NEARLINE"
expiry_days=80  # for Nearline object class # fucking early deletion fee comes even if I delete files older than 40 days

# Error handling
send_email() {
  error_msg=$(date +%c)": ERROR in $0 : line $1 with exit code $2"
  echo "$error_msg" | mailx -s "RasPi Backup Error" gwindlord@gmail.com -A /var/log/system_backup.log
  echo "$error_msg"
  exit 1
}
trap 'send_email ${LINENO} ${?}' ERR SIGTERM SIGKILL SIGHUP


# Check that we are root!
if [[ ! $(whoami) =~ "root" ]]; then
echo ""
echo "**********************************"
echo "*** This needs to run as root! ***"
echo "**********************************"
echo ""
exit 2
fi

# Check to see if we got command line args
if [ ! -z $1 ]; then
   backup_path=$1
fi

if [ ! -z $2 ]; then
   retention_days=$2
fi

if [ ! -z $3 ]; then
   backup_bucket=$3
fi


backup_name="$backup_path/$HOSTNAME.$(date +%F).img.gz"


echo $(date +%c)": Deleting backups older than $retention_days days"
#find $backup_path/$HOSTNAME.*.img.gz -mtime +$retention_days -type f -delete
find $backup_path/$HOSTNAME.* -type f -mtime +$retention_days -delete || echo $(date +%c)": No old backups found to delete"

echo $(date +%c)": Creating trigger to force file system consistency check if image is restored"
touch /boot/forcefsck

echo $(date +%c)": Performing backup to $backup_name"
# dd bs=M if=/dev/mmcblk0 of=$backup_path/$HOSTNAME.$(date +%F).img
dd bs=4M if=/dev/mmcblk0 | gzip > "$backup_name"

echo $(date +%c)": Calculating MD5"
md5sum "$backup_name" > "$backup_name".md5

echo $(date +%c)": Removing fsck trigger"
rm /boot/forcefsck

echo $(date +%c)": Backup file size "$(ls -l "$backup_name" | awk '{print $5}')

echo $(date +%c)": Uploading backup $backup_name{.md5} to cloud $backup_bucket"
# separate uploads to get at least md5 uploaded if network drops on image
gsutil cp -c "$backup_name".md5 "$backup_bucket"
gsutil -o GSUtil:parallel_composite_upload_threshold=150M cp -c "$backup_name" "$backup_bucket"

echo $(date +%c)": Rotating backups of class $storage_class and older than $expiry_days days in bucket $backup_bucket"
term_in_seconds=$(expr $expiry_days \* 24 \* 60 \* 60)
current_time=$(date "+%s")  # use Unicode timestamp in seconds
objects=$(gsutil ls -la "$backup_bucket" | awk '{print $2,$3}' | head -n -2)
IFS=$'\n'
for line in $objects
do
  objdate=$(date "+%s" -d $(awk '{print $1}' <<< "$line"))
  objname=$(awk '{print $2}' <<< "$line")
  age=$(expr $current_time - $objdate)
  if [ $age -ge $term_in_seconds ]; then
     objclass=$(gsutil ls -La "$objname" | grep "Storage class:" | awk '{print $3}')
     if [[ "$objclass" == "$storage_class" ]]; then
       # if object's age in seconds is bigger than seconds from objects timestamp to now
       # and its class is similar to necessary storage class, it's subject for removal
       echo $(date +%c)": Object $objname aged $age seconds from $objdate, is older than $expiry_days days ($term_in_seconds seconds) from today's $current_time"
       gsutil rm -f "$objname"
     fi
  fi
done

echo -e $(date +%c)": Process completed\n\n"
