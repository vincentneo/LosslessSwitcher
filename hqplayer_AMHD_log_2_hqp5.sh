#!/bin/bash
#
HQPHOSTDEFAULT="localhost"
HQPHOST="${1:-$HQPHOSTDEFAULT}"
#
defsamlerateapp="LosslessSwitcher"
samlerateapp="${2:-$defsamlerateapp}"
#
AMHDlog="/Users/$USER/Library/Application Support/Amazon Music/Logs/AmazonMusic.log"
GREPfor="Audio Attributes updated"
#
tailcmd="tail -f \"$AMHDlog\" | grep 'Audio Attributes updated'"
#
echo "$0 starts for $HQPHOST -- $tailcmd"
#
#
tail  -f "$AMHDlog" | grep --line-buffered "$GREPfor" |
 while IFS= read -r LINE0 
#while read LINE0
do
  newrate=""
#
  if echo "$LINE0"  |  grep -q -E "Audio Quality: HD44"; then 
    newrate="44100"
  elif echo "$LINE0" | grep -q -E "Audio Quality: UHD44"; then 
    newrate="44100"
  elif echo "$LINE0" | grep -q -E "Audio Quality: HD48"; then 
    newrate="48000"
  elif echo "$LINE0" | grep -q -E "Audio Quality: UHD48"; then 
    newrate="48000"
  elif echo "$LINE0" | grep -q -E "Audio Quality: UHD88"; then 
    newrate="88000"
  elif echo "$LINE0" | grep -q -E "Audio Quality: UHD96"; then 
    newrate="96000"
  elif echo "$LINE0" | grep -q -E "Audio Quality: UHD192"; then 
    newrate="192000"
  else
    newrate=""  
  fi 
#
  if [[ $newrate != "" ]]
  then
     echo "changing $HQPHOST to $newrate"
     /Applications/hqp5-control.app/Contents/MacOS/hqp5-control $HQPHOST --set-transport-rate audio:default/$newrate/2

     echo "changing $samlerateapp to $newrate"
     osascript -e "tell application \"$samlerateapp\" to setsamplerate rate $newrate"ls
 

     echo "changed to $newrate"

  fi
#
#done < <( $tailcmd )
done
#
echo "$0 done"
#

