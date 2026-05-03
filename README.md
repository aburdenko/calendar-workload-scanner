# Calendar Workload Scanner

This Google Apps Script automates checking your calendar for new meetings to ensure they have an associated Vector Workload link.

## How It Works

The script runs in the background every 30 minutes and scans your calendar for the next 30 days, looking for new meetings that meet all of the following criteria:

1. **You are an attendee**, but **not the organizer** (and you are explicitly on the guest list).
2. **The meeting was organized by a Googler** (the creator's email ends with `@google.com`).
3. **There are external stakeholders** (at least one guest on the invite has a non-`@google.com` email address).
4. **The meeting is brand new** (it was created within the last 1 hour).
5. **You have not RSVP'd yet** (your status is strictly "Invited").

If an event meets all the criteria above, the script checks the meeting description for:
- A Vector Workload link that starts with `https://vector.lightning.force.com/lightning/r/Workload__c/` (this default can be overridden via the `WORKLOAD_LINK_PREFIX` Script Property or set in your local `.env` file).

### Action Taken
If the meeting meets all the criteria, the script will:

1. **Automatically create a Meeting Agenda:** It intelligently routes the agenda to a specific customer's Google Doc based on keyword overlaps. It compares the Meeting Title with the aliases provided in your configuration (`NOTES_DOC_KEYS`) and prepends a structured agenda (Date, Title, Attendees, Workload Link, Notes, and Action Items) to the "Notes" tab of the matched document.
2. **Check the Workload Link:** If the Workload Link is not found in the description:
   - Sets your RSVP to **"Tentative"**.
   - Sends an automated email to the organizer with the event title, date, and a note:
     *"Awaiting Vector Workload ID. Please update the description to confirm Alex's attendance."*

## Setup and Deployment

This project uses `clasp` (the Google Apps Script CLI) and a custom VS Code task for easy deployment. The deployment script automatically synchronizes your local `.env` variables to Apps Script.

### 1. Prerequisites
1. Copy the `.env-COPY` template to a new file named `.env`:
   ```bash
   cp .env-COPY .env
   ```
2. Fill in the required variables in your `.env` file:
   - **GCP Authentication:** The deployment script uses `.scripts/configure.sh` to authenticate via a Service Account. You must provide `PROJECT_ID`, `GOOGLE_CLOUD_PROJECT`, `REGION`, `PROJECT_NUMBER`, and the path to your service account key in `GOOGLE_APPLICATION_CREDENTIALS`.
   - **App Configuration:** 
     - **`NOTES_DOC_KEYS`**: A semicolon-separated list of document aliases or shortlinks (e.g., `"go/merck-notes-2026;go/pfizer-notes"`). The script extracts keywords from these keys (e.g., "merck") and matches them against new calendar event titles.
     - **`NOTES_DOC_VALUES`**: A semicolon-separated list of corresponding Google Doc URLs or IDs (e.g., `"https://docs.google.com/document/d/18RB_.../edit;https://docs.google.com/document/d/ANOTHER_ID/edit"`). These must map 1-to-1 with the keys above.
     - **`WORKLOAD_LINK_PREFIX`**: Ensure this is set (it defaults to the Salesforce Vector URL).
     - **`APP_SCRIPT_IDS`**: Leave this blank if you are deploying for the first time.

### 2. Deploying
You can deploy the script directly from VS Code:
1. Open the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P`).
2. Select **Tasks: Run Task**.
3. Select **Deploy Calendar Workload Scanner**.

**What the deployment script does:**
- If the `APP_SCRIPT_IDS` variable in your `.env` is empty, it will automatically run `clasp create` to build a new standalone Apps Script project. It will extract the new Script ID, save it into your `.env` file, and push the code.
- If `APP_SCRIPT_IDS` already contains an ID, it will simply run `clasp push` to update the existing script with the latest code.

### 3. Activating the Trigger
After you deploy for the first time, you must manually activate the background trigger:
1. Open the [Google Apps Script Dashboard](https://script.google.com/).
2. Open the newly created "Calendar Workload Scanner" project.
3. Select the `Code.js` file.
4. At the top of the editor, select the `setupTrigger` function from the dropdown menu next to the "Run" button.
5. Click **Run**.
6. Follow the on-screen prompts to grant the necessary calendar and email permissions to the script.

Once executed, the script will automatically run in the background every 30 minutes.
