# Calendar Workload Scanner

This Google Apps Script automates checking your calendar for new meetings to ensure they have an associated Vector Workload link.

## How It Works

The script runs in the background every hour and scans your calendar for the next 30 days, looking for new meetings that meet all of the following criteria:

1. **You are an attendee**, but **not the organizer**.
2. **The meeting was organized by a Googler** (the creator's email ends with `@google.com`).
3. **There are external stakeholders** (at least one guest on the invite has a non-`@google.com` email address).
4. **You have not already declined or set your RSVP to tentative**.

If an event meets all the criteria above, the script checks the meeting description for:
- A Vector Workload link that starts with `https://vector.lightning.force.com/lightning/r/Workload__c/` (this default can be overridden via the `WORKLOAD_LINK_PREFIX` Script Property or set in your local `.env` file).

### Action Taken
If the link is not found in the description, the script automatically:
1. Sets your RSVP to **"Tentative"**.
2. Appends a note to the calendar event's description:
   *"Awaiting Vector Workload ID. Please update the description to confirm Alex's attendance."*
3. Sends an automated email to the organizer with the same note, the event title, and the date.

## Setup and Deployment

This project uses `clasp` (the Google Apps Script CLI) and a custom VS Code task for easy deployment.

### 1. Prerequisites
Ensure your local environment is configured with the required `.env` file containing an `APP_SCRIPT_IDS` key and the `WORKLOAD_LINK_PREFIX`.

### 2. Deploying
You can deploy the script directly from VS Code:
1. Open the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P`).
2. Select **Tasks: Run Task**.
3. Select **Deploy Calendar Workload Scanner**.

**What the deployment script does:**
- If the `APP_SCRIPT_IDS` variable in your `.env` is empty, it will automatically run `clasp create` to build a new standalone Apps Script project. It will extract the new Script ID, save it into your `.env` file, and push the code.
- If `APP_SCRIPT_IDS` already contains an ID, it will simply run `clasp push` to update the existing script with the latest code.

### 3. Activating the Hourly Trigger
After you deploy for the first time, you must manually activate the background trigger:
1. Open the [Google Apps Script Dashboard](https://script.google.com/).
2. Open the newly created "Calendar Workload Scanner" project.
3. Select the `Code.js` file.
4. At the top of the editor, select the `createHourlyTrigger` function from the dropdown menu next to the "Run" button.
5. Click **Run**.
6. Follow the on-screen prompts to grant the necessary calendar and email permissions to the script.

Once executed, the script will automatically run in the background every hour.
