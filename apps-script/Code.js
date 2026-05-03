/**
 * Scans the calendar every hour for new meetings where the user is an attendee but not the organizer.
 * If the description lacks a Vector Workload link, sets RSVP to Tentative,
 * adds a note to the event, and emails the organizer.
 */

function scanCalendarAndRespond() {
  const now = new Date();
  const futureDate = new Date(now.getTime() + (30 * 24 * 60 * 60 * 1000));
  const events = CalendarApp.getDefaultCalendar().getEvents(now, futureDate);
  const myEmail = Session.getActiveUser().getEmail();

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
      for (let i = 0; i < guests.length; i++) {
        if (!guests[i].getEmail().toLowerCase().endsWith('@google.com')) {
          hasNonGoogler = true;
          break;
        }
      }

      if (!hasNonGoogler) {
        return;
      }

      const myStatus = event.getMyStatus();
      if (myStatus === CalendarApp.GuestStatus.DECLINED || myStatus === CalendarApp.GuestStatus.TENTATIVE) {
        return;
      }

      const description = event.getDescription() || "";
      const workloadPrefix = PropertiesService.getScriptProperties().getProperty('WORKLOAD_LINK_PREFIX') || "https://vector.lightning.force.com/lightning/r/Workload__c/";
      const hasWorkloadLink = description.includes(workloadPrefix);

      if (!hasWorkloadLink) {
        event.setMyStatus(CalendarApp.GuestStatus.TENTATIVE);
        
        const note = "Awaiting Vector Workload ID. Please update the description to confirm Alex's attendance.";
        
        try {
          event.setDescription(description + "\n\nNote: " + note);
        } catch (e) {
          console.log("Could not update description for event: " + event.getTitle());
        }
        
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

function createHourlyTrigger() {
  const triggers = ScriptApp.getProjectTriggers();
  for (let i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === 'scanCalendarAndRespond') {
      console.log("Trigger already exists.");
      return;
    }
  }
  
  ScriptApp.newTrigger('scanCalendarAndRespond')
      .timeBased()
      .everyHours(1)
      .create();
  console.log("Hourly trigger created successfully.");
}
