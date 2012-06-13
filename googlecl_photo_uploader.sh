#!/bin/bash

# Configuration Variables
photo_dir=""
email_address=""
force_db_update=false
skip_db_check=false

# Check the arguments
usage()
{
cat << EOF
Usage: $0 options
This script uploads photos from a specified directory to Picasa Web Albums

Options
  -h	Show this message
  -d	The photo directory (Mandatory)
  -e	The google email login (Mandatory)
  -f	Force an update of the local database
  -s	Skip checking the database is up to date
EOF
}

while getopts hd:e:fs opt
do
  case "$opt" in
    h) 
      usage
      exit 1
      ;;
    d) photo_dir=$OPTARG;;
    e) email_address=$OPTARG;;
    f) force_db_update=true;;
    s) skip_db_check=true;;
    *) 
      usage
      exit 1
      ;;
  esac
done

if [[ $photo_dir == "" || $email_address == "" ]]
then
  echo -e "\n\n***\nPlease ensure you supply a photo directory and email address.\n***\n\n"
  usage
  exit 1
fi

if [ ! -d $photo_dir ]
then
  echo -e "\"$photo_dir\" is not a valid directory.\nExiting."
  exit 1
fi

# Check we have googlecl installed
command -v google >/dev/null 2>&1 || { echo >&2 -e "Googlecl doesn't appear to be available.\nExiting."; exit 1; }

# Check we have sqlite3
command -v sqlite3 >/dev/null 2>&1 || { echo >&2 -e "Sqlite3 doesn't appear to be available.\nExiting."; exit 1; }

# Check we have curl
command -v curl >/dev/null 2>&1 || { echo >&2 -e "Curl doesn't appear to be available.\nExiting."; exit 1; }

# Check we have xpath
command -v xpath >/dev/null 2>&1 || { echo >&2 -e "Xpath doesn't appear to be available.\nExiting."; exit 1; }

# Create the database dir if it doesn't exist
config_dir=$(basename $0 .sh)
if [ ! -d $HOME/.config/$config_dir ]
then
  mkdir -p $HOME/.config/$config_dir
fi
database="$HOME/.config/$config_dir/google_output.db"
# Delete the database if force_db_check is set and skip_db_check is not set
if [[ $force_db_update == true && $skip_db_check == false ]]
then
  rm -f "$database"
fi
#NOW=$(date +"%Y%m%d%H%M")
#database="~/.config/$config_dir/google_output_$NOW.db"
# Create the database if it doesn't exist
if [ ! -e $database ]
then
  sqlite3 $database "create table all_photos (key INTEGER PRIMARY KEY, album TEXT, access TEXT, title TEXT, summary TEXT, published TEXT, updated TEXT, timestamp INTEGER, url TEXT, make TEXT, model TEXT, tags TEXT);" 
fi

# Check we have curl authorisation or set it up. The google auth token will expire after a day so we'll delete the file in that case.
find $HOME/.config/$config_dir -name curl_auth.txt -mtime +1 -delete
if [[ ! -f $HOME/.config/$config_dir/curl_auth.txt ]]
then
  read -s -p "Enter the password for $email_address and press [ENTER]: " passwd
  curl https://www.google.com/accounts/ClientLogin --data-urlencode Email=$email_address --data-urlencode Passwd=$passwd -d accountType=GOOGLE -d source=Google-cURL-Example -d service=lh2 -o $HOME/.config/$config_dir/curl_auth.txt 2>/dev/null
fi
auth=$(grep Auth= $HOME/.config/$config_dir/curl_auth.txt | sed 's/Auth=//g')

#
# Get the albums from google
#
echo -e ""
echo -e "Querying picasa web albums for the current albums."
# Array variable to store all the information from Picasa
data=() 
# Associative array used to check if the title is a duplicate
declare -A titles
# Array to store the duplicate titles
duplicates=()
# An associative array containing the access level
declare -A access
# Save the old IFS and use a newline
old_ifs="$IFS"
IFS=$'\n'
# Loop through each line of output from googlecl
while read i
do
  # Create an array with the split parts of the line, e.g. title, summary, etc
  IFS=$'|'
  values=( $i )
  IFS=$'\n'
  # Append the full line of data
  data=("${data[@]}" "$i")
  # Check if the title is already in the titles associative array
  #echo "Checking for duplicate album: ${values[0]}"
  # Start with a quick scalar check
  if [[ ${titles[@]} =~ ${values[0]} ]]
  then
    # Now perform the slower check of each element
    is_duplicate=0
    for title in "${titles[@]}"
    do 
      if [[ $title == "${values[0]}" ]]
      then
        is_duplicate=1
        break
      fi
    done
    if [[ $is_duplicate -eq 0 ]]
    then
      # If not, add it as a new item
      titles[${#titles[*]}]="${values[0]}"
      access[${#access[*]}]="${values[1]}"
    else
      # If so, add it to the duplicates array
      duplicates=("${duplicates[@]}" "$i")
      #echo "\tDuplicate title: [${values[0]}]"
    fi
  else
    # If the scalar check failed then it's not in the array and we can add it.
    titles[${#titles[*]}]="${values[0]}"
    access[${values[0]}]="${values[1]}"
  fi
done < <(google picasa list-albums --fields=title,access --delimiter="|")

# Print any duplicates and exit
for i in ${duplicates[@]}
do
  # Awaiting answer from https://groups.google.com/forum/?fromgroups#!topic/googlecl-discuss/CITpMsvLrbk
  echo -e "\tDuplicate Title: [$i]"
done
if [[ ${#duplicates[@]} > 0 ]]
then
  echo -e "Please resolve the duplicate album titles before running again."
  exit 1
fi

# Loop through the albums and populate the db with each photo
if [[ $skip_db_check != true ]] 
then
  for album in ${titles[@]}
  do
    echo -e "Reading Album: $album"
    echo -e "\tAccess: "${access["$album"]}""
    while read i
    do
      IFS='|'
      parts=( $i )
      IFS='\n'
      echo -e "\tTitle:\t\t${parts[0]}"
      echo -e "\tSummary:\t${parts[1]}"
      echo -e "\tPublished:\t${parts[2]}"
      echo -e "\tUpdated:\t${parts[3]}"
      echo -e "\tTimestamp:\t${parts[4]}"
      echo -e "\tURL:\t\t${parts[5]}"
      echo -e "\tMake:\t\t${parts[6]}"
      echo -e "\tModel:\t\t${parts[7]}"
      echo -e "\tTags:\t\t${parts[8]}"
      IFS=$old_ifs
      sqlite3 $database "insert into all_photos (album, access, title, summary, published, updated, timestamp, url, make, model, tags) values (\"$album\", \"${access[$album]}\", \"${parts[0]}\", \"${parts[1]}\", \"${parts[2]}\", \"${parts[3]}\", \"${parts[4]}\", \"${parts[5]}\", \"${parts[6]}\", \"${parts[7]}\", \"${parts[0]}\");"
    done < <(google picasa list "^$album\$" --fields=title,summary,published,updated,timestamp,url-site,make,model,tags --delimiter="|")
  done
else
  echo "Skipping checking of the database. Assuming the database is completely accurate."
fi

# Get the latest published date from the database
latest_db_updated=$(sqlite3 $database "SELECT title,updated FROM all_photos ORDER BY updated DESC LIMIT 1;")
echo -e "The latest updated date from the database is $latest_db_updated."

# Get the latest updated file from google

# According to https://developers.google.com/picasa-web/docs/2.0/developers_guide_protocol#ListRecentPhotos
# I should be able to get the most recently uploaded item. My testing showed this didn't work. If you get 
# the data for the last 10 it does give this information. I decided to get the last 50 just to make sure here.
curl --silent --header "Authorization: GoogleLogin auth=$auth" "http://picasaweb.google.com/data/feed/api/user/default?kind=photo&max-results=50"|tidy -xml -indent -quiet > $HOME/.config/$config_dir/latest.xml
# I'm sure there's a more elegant way to extract the title and date of the latest upload but for now I've gone with this
IFS=$'\n'
datesxml=$(xpath -e "feed/entry/updated/text()" $HOME/.config/$config_dir/latest.xml 2>/dev/null)
titlesxml=$(xpath -e "feed/entry/title/text()" $HOME/.config/$config_dir/latest.xml 2>/dev/null)
dates_xml_values=()
titles_xml_values=()
# Populate the arrays
for i in $datesxml
do
  dates_xml_values=("${dates_xml_values[@]}" "$i")
done
for i in $titlesxml
do
  titles_xml_values=("${titles_xml_values[@]}" "$i")
done
# Find the latest entry
latest_index=0
for (( i=1;i<${#dates_xml_values[@]};i++ ))
do
  latest_time=$(date -d ${dates_xml_values[$latest_index]%\.*} +%s)
  test_time=$(date -d ${dates_xml_values[$i]%\.*} +%s)
  if [[ $test_time -gt $latest_time ]]
  then
    latest_index=$i
  fi
done

latest_online_updated="${titles_xml_values[$latest_index]}|${dates_xml_values[$latest_index]}"
echo -e "The latest updated date online is $latest_online_updated."

# If the latest updates are different, exit
if [[ $latest_db_updated != $latest_online_updated ]]
then
  echo -e "The latest updated photo in the database and online do not match. Exiting - please re-run using the force_db_update option."
  exit 1
fi

# Loop through all the photo directories and upload any photos not in the database
IFS=$'\n'
albums_requiring_field_updates=()
echo -e "Searching $photo_dir for image files not yet uploaded."
for i in $(find $photo_dir -mindepth 1 -type d)
do
  # Get the album name
  album_name=$(echo $i | sed -e 's!'"$photo_dir"'!!g' | sed -e 's/\/JPEG//g' | sed -e 's/\// - /g')
  echo -e "Album: $album_name"

  # Query the database to get any images for that album
  album_images=$(sqlite3 $database "SELECT title FROM all_photos WHERE album=\"$album_name\"")
  
  for j in $(find $i -mindepth 1 -maxdepth 1 -type f -iname "*.jpg" -o -iname "*.jpeg")
  do
    basename=$(basename "$j")
    if [[ "$album_images" =~ "$basename" ]]
    then
      echo -e "\tAlready uploaded: $j"
    else
      # Create the album if it doesn't exist
      # TODO - This won't work if a new album_name is a subset of an old name
      if [[ ! ${titles[@]} =~ $album_name ]]
      then
        echo -e "Album doesn't exist. Creating."
        output=$(google picasa create "$album_name" --access=private)
        #echo "$output"
        titles[${#titles[*]}]="$album_name"
        access[${#access[*]}]="private"
      fi
      #echo -e "\t***Uploading: $j"
      output=$(google picasa post "$album_name" --src "$j" --summary "$basename" --tags AutoUploaded)
      #echo "$output"
      #sqlite3 $database "insert into all_photos (album, title, summary, url, tags) values (\"$album_name\", \"$basename\", \"$basename\", \"UpdateMe\", \"AutoUploaded\");"
      albums_requiring_field_updates=("${albums_requiring_field_updates[@]}" "$album_name")
    fi
  done 
done

echo -e "\n\nFinished uploading. Reading values back from google for inclusion in the database."

for album in ${albums_requiring_field_updates[@]};
do
  sqlite3 $database "DELETE FROM all_photos WHERE album=\"$album\";"
  echo -e "Reading Album: $album"
  echo -e "\tAccess: "${access["$album"]}""
  while read i
  do
    IFS='|'
    parts=( $i )
    IFS='\n'
    echo -e "\tTitle:\t\t${parts[0]}"
    echo -e "\tSummary:\t${parts[1]}"
    echo -e "\tPublished:\t${parts[2]}"
    echo -e "\tUpdated:\t${parts[3]}"
    echo -e "\tTimestamp:\t${parts[4]}"
    echo -e "\tURL:\t\t${parts[5]}"
    echo -e "\tMake:\t\t${parts[6]}"
    echo -e "\tModel:\t\t${parts[7]}"
    echo -e "\tTags:\t\t${parts[8]}"
    IFS=$old_ifs
    sqlite3 $database "insert into all_photos (album, access, title, summary, published, updated, timestamp, url, make, model, tags) values (\"$album\", \"${access[$album]}\", \"${parts[0]}\", \"${parts[1]}\", \"${parts[2]}\", \"${parts[3]}\", \"${parts[4]}\", \"${parts[5]}\", \"${parts[6]}\", \"${parts[7]}\", \"${parts[0]}\");"
  done < <(google picasa list "^$album\$" --fields=title,summary,published,updated,timestamp,url-site,make,model,tags --delimiter="|")
done

IFS="$old_ifs"

exit 0
