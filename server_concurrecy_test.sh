#!/usr/bin/env sh

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

start_client() {
  local username="$1"
  local interval="$2"
  local color="$3"
  local counter=1

  echo -e "${color}Starting client: ${username}${NC}"

  # Use a named pipe to read server responses
  local pipe="/tmp/${username}_pipe"
  mkfifo "$pipe"

  # Start reading server responses in background
  cat "$pipe" | while read -r response; do
    echo -e "${color}${username} received: ${response}${NC}"
  done &

  # Send messages to server
  {
    while true; do
      timestamp=$(date +"%H:%M:%S")
      echo "${username}: message $counter"
      counter=$((counter + 1)) # Fixed increment syntax
      sleep "$interval"
    done
  } | nc localhost 1234 >"$pipe"

  # Cleanup
  rm -f "$pipe"
  echo -e "${color}${username} disconnected${NC}"
}

# Start each client
start_client "bob" 1 "$RED" &
sleep 1
start_client "angela" 2 "$GREEN" &
sleep 1
start_client "merkel" 3 "$BLUE" &

# Wait for all clients
wait
