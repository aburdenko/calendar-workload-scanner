#!/bin/bash
# Sources the local environment and deploys the Apps Script.
# If APP_SCRIPT_IDS is empty, creates a new script, saves the ID, and pushes.
# If APP_SCRIPT_IDS has values, loops through and pushes to each.

# Load environment variables
if [ -f .env ]; then
  export $(grep -v '^#' .env | grep -v '^$' | sed 's/=\(.*\)/="\1"/g' | sed 's/""/"/g')
fi

# The configure.sh script seems to exist in the original tasks.json, let's source it if it exists.
if [ -f .scripts/configure.sh ]; then
  source .scripts/configure.sh
fi

if [ -z "$APP_SCRIPT_IDS" ]; then
  echo "APP_SCRIPT_IDS is empty. Creating a new Google Apps Script from scratch..."
  
  # Remove old .clasp.json if it exists so create doesn't fail
  rm -f .clasp.json apps-script/.clasp.json
  
  # Create a new standalone project
  # clasp create outputs something like: "Created new standalone script: https://script.google.com/d/1LUgm.../edit"
  CREATE_OUTPUT=$(clasp create --type standalone --title "Calendar Workload Scanner" --rootDir apps-script)
  echo "$CREATE_OUTPUT"
  
  # Extract the Script ID from .clasp.json
  if [ -f .clasp.json ]; then
    NEW_SCRIPT_ID=$(grep -o '"scriptId": *"[^"]*' .clasp.json | grep -o '[^"]*$')
  elif [ -f apps-script/.clasp.json ]; then
    NEW_SCRIPT_ID=$(grep -o '"scriptId": *"[^"]*' apps-script/.clasp.json | grep -o '[^"]*$')
    # Move it to the root
    mv apps-script/.clasp.json .clasp.json
  fi
  
  if [ -n "$NEW_SCRIPT_ID" ]; then
    echo "Successfully created script with ID: $NEW_SCRIPT_ID"
    
    # Update .env with the new ID
    if grep -q "^APP_SCRIPT_IDS=" .env; then
      sed -i "s/^APP_SCRIPT_IDS=.*/APP_SCRIPT_IDS=\"$NEW_SCRIPT_ID\"/" .env
    else
      echo "APP_SCRIPT_IDS=\"$NEW_SCRIPT_ID\"" >> .env
    fi
    export APP_SCRIPT_IDS="$NEW_SCRIPT_ID"
    
    echo "Pushing code to the new script..."
    clasp push --force
    echo "Deployment complete! Please go to https://script.google.com/d/$NEW_SCRIPT_ID/edit to run createHourlyTrigger() manually once."
  else
    echo "Error: Failed to extract Script ID after clasp create."
    exit 1
  fi

else
  echo "APP_SCRIPT_IDS found. Updating existing scripts..."
  IFS=";" read -ra IDS <<< "$APP_SCRIPT_IDS"
  for id in "${IDS[@]}"; do
    if [ -n "$id" ]; then
      echo "Deploying to Script ID: $id"
      echo "{\"scriptId\":\"$id\", \"rootDir\": \"apps-script\"}" > .clasp.json
      clasp push --force
    fi
  done
  echo "Deployment to all existing scripts complete!"
fi
