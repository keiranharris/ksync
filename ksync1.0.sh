#!/bin/sh

########################################
# VERSION:  1.0
# UPDATED:  28/5/2016
# DESCRIP:  local sync (and rolling snapshot) of a nominated CIFS/SMB network share
#   NOTES:  this has been setup initially for CBA gig sync. To add to this, just duplicate ### lines with new target
#           this script relies on
#               1/ installation of unison (file sync utility)... see evernote for my cheatsheet
#               2/ its config file configured, locaton: "/Users/keiran_harris/Library/Application Support/Unison/_CBA.prf"
#               3/ putting::     UNISONLOCALHOSTNAME="pro15" ; export UNISONLOCALHOSTNAME      in .bashrc file (otherwise unison continually thinks its a new sync when my IP/location chanegs)
#  TRICKY:  string handling, "O2 Fileshare" has a space in it which mount_smbfs doesnt like (nor does funtion argument passing) without special handling...
########################################

# TO DO:
#m - handle multiple mounts... should be ok cause CreateTmpMountFileAndArray filters on IP... so wont be multiple for 10.208.83.106

#GLOBAL VARIABLES (ANNOYING, BUT BASH FORCED MY HAND).
O2GIG=""
USERNAME="c920835"
PASS="321Work!18"
O2SHAREIP="10.208.83.106"
O2SHARENAME="O2 Fileshare"   #SOME MUPPET PUT A SPACE IN THE O2 SHARENAME, SO SPECIAL HANDLING OF THIS REQUIRED BELOW...
DAYSOLD=""

declare -a ARGUMENTS            #if user enters multiple choices in menu, they are stored here
declare -a CURRENTMOUNTS        #array of our current mounts (as this program sees them).
#--------------------------------------------------------------------------------
#CREATE /tmp/kmount.tmp AND SETUP CURRENTMOUNTS ARRAY (FOR UMOUNTING SELECTED MOUNTS). $1=NAS-NAME/IP
CreateTmpMountFileAndArray () {
    #make a tmp mount file (matching only our remote mounts) to make later operations easier
    mount | grep $1 > /tmp/kmount.tmp

    #setup an array of remote mounts
    i=0
    while read remoteMount allOtherCrap     #allOtherCrap captures everything after first IFS (space)
    do
        CURRENTMOUNTS[$i]=$remoteMount
        i=$i+1
    done </tmp/kmount.tmp
}

#--------------------------------------------------------------------------------
#DISPLAY A MENU
PrintMenu () {
    #GET LAST SYNC TIME FROM FILE
    while IFS='' read -r line || [[ -n "$line" ]]; do
        LASTSYNCTIME="$line"
    done < "/_LOCALDATA/K-WORK/_UNISON-SYNC/_$O2GIG/timestamp.txt"

    #GET LAST SNAP TIME FROM FILE
    while IFS='' read -r line || [[ -n "$line" ]]; do
        LASTSNAPTIME="$line"
    done < "/_LOCALDATA/_SNAPSHOTS/_LANSYNC/_$O2GIG/timestamp.txt"

    clear
    echo "---------- Welcome to the kSYNC Program ----------"
    echo "|                                                |"
    echo "| O2 CUSTOMER:: $O2GIG                              |"
    echo "|                                                |"
    echo "|  (uf) unison-full  [last sync: $LASTSYNCTIME]  |"
    echo "|  (uc) unison-curr  [last sync: $LASTSYNCTIME]  |"
    echo "|  ( s) snapshot-bak [last snap: $LASTSNAPTIME]  |"
    echo "|                                                |"
    echo "|  ( m) mount                                    |"
    echo "|  ( d) dismount                                 |"
    echo "|                                                |"
    echo "|  ( r) refresh (this screen)                    |"
    echo "|                                                |"
    echo "|  ( q) quit                                     |"
    echo "|                                                |"
    PrintCurrentMounts
}
#BASED OFF OUR CURRENTMOUNTS ARRAY, LIST OUT OUR MOUNTS
PrintCurrentMounts () {
    echo "-----------------CURRENT MOUNTS-------------------"
    #ITERATE THROUGH CURRENTMOUNTS PRINTING IT OUT...
    max=${#CURRENTMOUNTS[*]}    #notation for working out the upper indicie of the array
    for (( k=0; k<$((max)); k=k+1 )); do
        echo "$((k+1)): ${CURRENTMOUNTS[k]}"        #ie print: "1: //keiran_harris@nas.i8/_INSTALL"
    done
    echo "--------------------------------------------------"
}

#POPULATE GLOBAL ARGUMENTS ARRAY WITH ALL (MAX 3) THE MENU ITEMS THE USER ENTERS
ReadMenuInput () {
    read -p " ENTER CHOICES (MULTIPLE OK, SPACE SEPARATED) ->" choices
    read c1 c2 c3 <<<"$choices"

    #fill the array with choices (perhaps arguments 2 and 3 dont exist)
    ARGUMENTS[0]=$c1
    [[ -n $c2 ]] && ARGUMENTS[1]=$c2
    [[ -n $c3 ]] && ARGUMENTS[2]=$c3
    #if more than 3 arguments are entered, break out of THIS ITERATION of the main menu loop
    myRegEx=".+ .*"
    if [[ "$c3" =~ $myRegEx ]]; then
        echo "max of 3 please!"
        sleep 1
        return 99       #error return
    else
        return 0        #healthy return
    fi
}

#HANDLES ALL THE VALID MENU INPUT
ProcessMenuCommand () {
    case $1 in
        uf)  MountSyncDismount "_$O2GIG"
#            Snapshot "_$O2GIG"
            ;;
        uc)  MountSyncDismount "_$O2GIG" "c"  #'c' in argument $2 is the 'current' flag
#            Snapshot "_$O2GIG"
            ;;

        s)  SnapshotBakAndRotate "_$O2GIG"
            ;;
        m)  ProcessMountLogic "${O2SHARENAME}"
            ;;
        d)  unmountNum=1 ; Unmount $unmountNum
            ;;
        r)  continue
            ;;
        q)  CleanExit
            ;;
        *)  echo "'$1' not a valid choice"
            sleep 1
            ;;
    esac
}

#--------------------------------------------------------------------------------
#IS HOST PINGING? $1=NAS-NAME/IP
CheckHostIsPinging () {
    ping -c 1 -t 1 $1 &> /dev/null
    if [[ $? -eq 0 ]]; then
        return 0        #healthy return
    else
        return 99       #failure return
    fi
}

#IS DRIVE ALREADY MOUNTED? $1=SHARENAME
CheckForExistingMounting () {
    #MOUNT_SMBFS COMMAND NEEDS SPECIAL CHARS REPLACED (SPACE IN SHARENAME WITH %20, ! IN PASSWORD WITH %21)
    O2SHARENAMEWITHMOUNTESC="${1// /%20}"
    mount | grep $O2SHARENAMEWITHMOUNTESC > /dev/null
    if [[ $? -eq 0 ]]; then
        return 0        #healthy return
    else
        return 99       #failure return
    fi
}

#--------------------------------------------------------------------------------
#CREATE LOCAL MOUNT DIR AND MOUNT THE REMOTE SHARE TO IT. $1=O2SHAREIP $2=O2SHARENAME $3=USERNAME $4=PASS
MountHost () {
    MOUNTPOINT="/Volumes/${2}"

    #MOUNT_SMBFS COMMAND NEEDS SPECIAL CHARS REPLACED (SPACE IN SHARENAME WITH %20, ! IN PASSWORD WITH %21)
    O2SHARENAMEWITHMOUNTESC="${2// /%20}"
    PASSWITHMOUNTESC="${4//!/%21}"

    #CHECK IF LOCAL MOUNT DIRECTORY EXISTS, IF IT DOESNT, CREATE IT
    if [[ -d /Volumes/$2 ]]; then
        echo "local mount point exists, continuing..."
    else
        echo "local mount point /Volumes/$2 doesn't exist, creating..."
        sudo chmod 777 /Volumes/    #NB: on sierra, this requires adding the following to /etc/sudoers   :    keiran_harris ALL = NOPASSWD: /bin/chmod
        mkdir "${MOUNTPOINT}"       #NB: if this mkdir fails (like it did in 10.12 sierra upgrade) you need to: "sudo chmod 777 /Volumes/"
    fi
    #ATTEMPT TO MOUNT THE REMOTE FS
    #NB: correct CLI syntax is:  "mount_smbfs //c920835:<<pass>>@10.208.83.106/O2%20Fileshare /Volumes/O2\ Fileshare"
    echo "Attempting to Mount..."
    mount_smbfs "//${3}:${4}@${1}/${O2SHARENAMEWITHMOUNTESC}"  "/Volumes/${2}"

    if [[ $? -eq 0 ]]; then
        echo "Mount Success!"
        return 0        #healthy return
    else
        echo "WARNING: Mount Failure!"
        return 99       #failure return
    fi
}

#CORE MOUNTING LOGIC (PING CHECK, ALREADY MOUNTED ETC). $1=SHARENAME (ALL OTHER $ ARE GLOBALS)
ProcessMountLogic () {
    echo "share $1 selected..."
    CheckHostIsPinging $O2SHAREIP
    #WAS THE PING HEALTH-CHECK OK?
    if [[ $? -eq 0 ]]; then
        echo "host $O2SHAREIP is pinging, checking mounting...."
        CheckForExistingMounting "${1}"
        #ALREADY MOUNTED?
        if [[ $? -eq 0 ]]; then
            echo "mounted already..."
        #NOT YET MOUNTED
        else
            echo "not mounted, attempting to mount..."
            MountHost $O2SHAREIP "${O2SHARENAME}" $USERNAME "${PASS}"
            #WAS THE MOUNT SUCCESSFUL?
            if [[ $? -eq 0 ]]; then
                #ALL GOOD, CREATE TMP FILE AND ARRAY
                echo "mounted OK."
                say "mownting OK"        #ozzie pronunciation!
                CreateTmpMountFileAndArray $O2SHAREIP
            else
                #CLEANUP FAILED MOUNT
                read -p "WARNING: mount failed! Removing /Volumes/$1 [hit enter to ack]"
                rmdir /Volumes/$1
            fi
        fi
    #CANT EVEN PING
    else
        read -p "WARNING: host $O2SHAREIP is NOT pinging, aborting! [hit enter to ack]"
        exit
    fi
    #sleep 1
}


MountSyncDismount() {
    #MOUNT SHARE, IF NECESSARY, REFRESH SCREEN SO WE CAN SEE THE NEW MOUNT...
    echo ""
    echo ""
    echo "--MOUNTING--"
    say "mownting"  &   #continue code execution with &, ozzie pronunciation!
    ProcessMountLogic "${O2SHARENAME}"
    PrintMenu

    #CALL UNISON, TIMESTAMP IT WITH A .TS TEXT FILE IN THE SYNC ROOT
    echo ""
    echo ""
    echo "--UNISON SYNC--"
    say "starting unison"    &   #continue code execution with &
    PRFFILE=$1
    if [[ $2 == "c" ]]; then
        #APPEND PRFFILE WITH 'c' TO POINT AT DIFFERENT UNISION PREF FILE (IE _WBC.prf vs _WBCc.prf)
        PRFFILE=$1$2
    fi
    unison $PRFFILE
    TIMESTAMP=`date "+%Y%m%d-%H%M"`
    UNISONTS="/_LOCALDATA/K-WORK/_UNISON-SYNC/$1/timestamp.txt"
    touch $UNISONTS
    echo "$TIMESTAMP" > $UNISONTS
    say "$1 sync complete"

    #DISMOUNT SHARE, REFRESH SCREEN SO WE CAN SEE REMOVED MOUNT...
    echo ""
    echo ""
    echo "--DISMOUNTING--"
    unmountNum=1
    Unmount $unmountNum
    unset CURRENTMOUNTS
    PrintMenu
}

Snapshot () {
    if LastSnapshotWasToday "$1" ; then
        say "last snapshot was today, return to menu" &
    else
        TODAYSDATE=`date "+%Y%m%d"`
        say "last snapshot was "
        if [[ $DAYSOLD -eq TODAYSDATE ]]; then
            say "never"
        elif [[ $DAYSOLD -eq 1 ]]; then
            say "$DAYSOLD day ago"
        else
            say "$DAYSOLD days ago"
        fi
        #SNAPSHOT?
        say "do you wish to snapshot?" &
        for (( i=10; i>0; i--)); do
            printf "\rHit any key to make a snapshot backup ($i seconds till auto-abort)."
            read -s -n 1 -t 1 MYINPUT

            if [ $? -eq 0 ]; then
                echo ""
                echo ""
                echo "--SNAPSHOT,BACKUP,ROTATE--"
                SnapshotBakAndRotate $1
                break
            fi
        done
    fi
}

LastSnapshotWasToday () {
    declare -a LASTSNAPSHOTARRAY    #derived from timestamp.txt in _SNAPSHOT dir, element 0 will be date, element 1 will be time.

    #GET LAST SYNC TIME FROM FILE
    while IFS='' read -r line || [[ -n "$line" ]]; do
        LASTSNAPSHOTTIME="$line"
    done < "/_LOCALDATA/_SNAPSHOTS/_LANSYNC/$1/timestamp.txt"

    IFS='-' read -ra LASTSNAPSHOTARRAY <<< "$LASTSNAPSHOTTIME"
    TODAYSDATE=`date "+%Y%m%d"`
    DAYSOLD=$((TODAYSDATE - LASTSNAPSHOTARRAY[0]))
#    echo "last snapshot: ${LASTSNAPSHOTARRAY[0]}"
#    echo "today: $TODAYSDATE"
#    echo "days old: $DAYSOLD"
#    sleep 5

    if [[ $DAYSOLD -gt 0 ]]; then
        return 1
    else
        return 0
    fi
}

SnapshotBakAndRotate () {
#    case $1 in
#        _CBA)           ### duplicate as needed.
            echo "aging out oldest snapshot"    ; rm -rf /_LOCALDATA/_SNAPSHOTS/_LANSYNC/$1minus2/
            echo "moving minus1 to minus2"      ; mv  /_LOCALDATA/_SNAPSHOTS/_LANSYNC/$1minus1/    /_LOCALDATA/_SNAPSHOTS/_LANSYNC/$1minus2/
            echo "creating minus1 copy"         ; cp  -a  /_LOCALDATA/_SNAPSHOTS/_LANSYNC/$1/      /_LOCALDATA/_SNAPSHOTS/_LANSYNC/$1minus1/
            echo "RSYNCing latest UNISON sync to snapshot dir" ; rsync  -av --del /_LOCALDATA/K-WORK/_UNISON-SYNC/$1    /_LOCALDATA/_SNAPSHOTS/_LANSYNC/

            #UPDATE TIMESTAMP (OVERWRITE THE TIMESTAMP THAT UNISON PROCESS HAS ALREADY WRITTEN TO HANDLE CASE WHEN THIS FUNCTION IS CALLED ON ITS OWN)
            TIMESTAMP=`date "+%Y%m%d-%H%M"`
            SNAPTS="/_LOCALDATA/_SNAPSHOTS/_LANSYNC/$1/timestamp.txt"
            echo "$TIMESTAMP" > $SNAPTS
            say "snapshot of $1 complete"
#            ;;
#    esac
}

#--------------------------------------------------------------------------------
#IF UNMOUNTING SPECIFIC, CALLED BEFORE UNMOUNT SO SPECIFIC MOUNT CAN BE SELECTED AND PASSED TO IT
UnmountSpecific () {
    clear
    PrintCurrentMounts
    read -p " ENTER UNMOUNT NUMBER ->" unmountNum
    Unmount $unmountNum
}

#ACTUAL UMOUNT (AND ERROR HANDLING). $1="all" OR array index of given share passed in from UnmountSpecific above
Unmount () {
    #SET THE mntPt STRING FOR USE BY UMOUNT SHELL CMD BELOW
    if [[ $1 == "all" ]]; then
        mntPt="/Volumes/_*"
    else
        i=$1-1      #-1 as my mount listing starts at 1, arrays indexes start at 0
        mntPt=${CURRENTMOUNTS[i]}
    fi
    #PERFORM THE ACTUAL UMOUNT
    umount $mntPt &> /dev/null
    if [[ $? -eq 0 ]]; then
        #ALL GOOD
        echo "$1 unmounted successfully..."
        say "dismownted"     #ozzie pronunciation!
    else
        #SOMETHING NOT UNMOUNTING, TRY MORE FORCEABLE
        diskutil unmount $mntPt  > /dev/null
        if [[ $? -eq 0 ]]; then
            read -p "$1 unmounted successfully (had to be forced)... [hit enter to ack]"
        else
            echo "WARNING: something couldn't unmount ok. Heres the open network files (lsof | grep Volumes): "
            lsof | grep Volumes
            read -p "Try again in a few secs [hit enter to ack]"
        fi
    fi
}

#--------------------------------------------------------------------------------
#CLEANEXIT CODE TO BE CALLED BY MENU 'q' OR BY ANY CONCEIVABLE SHELL EVENT (SEE traps BELOW)
CleanExit () {
    #NOT DOING MUCH AT THE MOMENT APART FROM EXITING
    exit 0
}

#FORCE CLEAN EXIT, REGARDLESS OF THE WAY PROGRAM TERMINATES
trap CleanExit SIGHUP      #event 1  (hang up. This is when user kills term window via GUI)
trap CleanExit SIGINT      #event 2  (ctrl+c)
trap CleanExit SIGTERM     #event 15 (terminate signal sent by kill)
trap CleanExit SIGKILL     #event 9  (terminate immediately from kernal)

#--------------------------------------------------------------------------------
#MAIN CODE
if [ "$#" -gt 1 ]; then
    echo "Illegal number of CLI arguments"
    echo "  Usage:      ksync gig       "
    echo "  [ where 'gig' (case insensitive) matches name of ~/Library/Application Support/Unison/_GIG.prf... ]"
    exit
fi

#READ IN CLI ARGUMENT #1 AND ASSIGN TO O2GIG, AND ENSURE IT UPPERCASE
O2GIG="$1"
O2GIG=$(echo $O2GIG | tr 'a-z' 'A-Z')

while true; do
    CreateTmpMountFileAndArray $O2SHARENAME
    PrintMenu
    ReadMenuInput
    #MAKE SURE ALL IS OK WITH INPUT BEFORE PROCEEDING, 99 FLAGS AN ISSUE
    if [[ $? -eq 99 ]]; then continue; fi   #'continue' breaks out of THIS ITERATION of the loop

    #FOR EACH MENU INPUT (ON A SINGLE LINE) PROCESS THAT COMMAND
    max=${#ARGUMENTS[*]}    #notation for working out the upper indicie of the array
    for (( k=0; k<$((max)); k=k+1 )); do
        ProcessMenuCommand ${ARGUMENTS[k]}
    done
    unset ARGUMENTS     #destroy arguments array at end of each iteration
    unset CURRENTMOUNTS
done
