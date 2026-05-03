/**
 * Scans the calendar every hour for new meetings where the user is an attendee but not the organizer.
 * If the description lacks a Vector Workload link, sets RSVP to Tentative,
 * adds a note to the event, and emails the organizer.
 */

function scanCalendarAndRespond() {
  const now = new Date();
  const futureDate = new Date(now.getTime() + (30 * 24 * 60 * 60 * 1000));
  const events = CalendarApp.getDefaultCalendar().getEvents(now, futureDate);
  const myEmail = Session.getActiveUser().getEmail().toLowerCase();

  events.forEach(event => {
    try {
      const creators = event.getCreators() || [];
      if (creators.includes(myEmail)) {
        return;
      }

      // Check if invited/organized by a Googler
      const isCreatedByGoogler = creators.some(email => email.toLowerCase().endsWith('@google.com'));
      if (!isCreatedByGoogler) {
        return;
      }

      // Check if there are any non-Google stakeholders
      const guests = event.getGuestList() || [];
      let hasNonGoogler = false;
      let amIAGuest = false;

      for (let i = 0; i < guests.length; i++) {
        const guestEmail = guests[i].getEmail().toLowerCase();
        if (guestEmail === myEmail) {
          amIAGuest = true;
        }
        if (!guestEmail.endsWith('@google.com')) {
          hasNonGoogler = true;
        }
      }

      if (!hasNonGoogler) {
        return;
      }

      // If I am not directly on the guest list (e.g. invited via a group), 
      // setting my status might throw "Invalid argument: status". 
      // We can only reliably set status if we are a known guest.
      if (!amIAGuest) {
        return;
      }

      const myStatus = event.getMyStatus();
      // Only process events where you have not responded yet
      if (myStatus !== CalendarApp.GuestStatus.INVITED) {
        return;
      }

      // To ensure we don't spam older un-RSVP'd events when the script is first deployed,
      // we only look at events created within the last 1 hour.
      const oneHourAgo = new Date(now.getTime() - (1 * 60 * 60 * 1000));
      if (event.getDateCreated() < oneHourAgo) {
        return;
      }

      const description = event.getDescription() || "";
      const workloadPrefix = PropertiesService.getScriptProperties().getProperty('WORKLOAD_LINK_PREFIX') || "https://vector.lightning.force.com/lightning/r/Workload__c/";
      const hasWorkloadLink = description.includes(workloadPrefix);

      if (!hasWorkloadLink) {
        try {
          // Wrap this specifically, as it's the source of the "Invalid argument: status" error.
          event.setMyStatus(CalendarApp.GuestStatus.MAYBE);
        } catch (statusError) {
          console.log(`Could not set status for event "${event.getTitle()}": ${statusError}`);
          // If we can't set status, we should probably skip sending the email so we don't spam them repeatedly.
          return; 
        }
        
        const note = "Awaiting Vector Workload ID. Please update the description to confirm Alex's attendance.";
        
        if (creators && creators.length > 0) {
          const creatorsToEmail = creators.join(",");
          const subject = `Action Required: Missing Workload ID for "${event.getTitle()}"`;
          const body = `${note}\n\nEvent: ${event.getTitle()}\nDate: ${event.getStartTime()}`;
          MailApp.sendEmail(creatorsToEmail, subject, body);
        }
      }
    } catch (err) {
      console.error("Error processing event: ", err);
    }
  });
}

function setupTrigger() {
  const triggers = ScriptApp.getProjectTriggers();
  // Delete existing triggers to ensure we apply the new 30-minute interval
  for (let i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === 'scanCalendarAndRespond') {
      ScriptApp.deleteTrigger(triggers[i]);
      console.log("Deleted old trigger.");
    }
  }
  
  ScriptApp.newTrigger('scanCalendarAndRespond')
      .timeBased()
      .everyMinutes(30)
      .create();
  console.log("30-minute trigger created successfully.");
}
