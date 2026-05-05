/**
 * Automatically triggers when calendar events are created or updated.
 * For new meetings where the user is an attendee but not the organizer:
 * If the description lacks a Vector Workload link, it sets RSVP to Tentative,
 * adds a note to the event, and emails the organizer.
 */

function onCalendarInviteArrival(e) {
  const now = new Date();
  const futureDate = new Date(now.getTime() + (30 * 24 * 60 * 60 * 1000));
  const events = CalendarApp.getDefaultCalendar().getEvents(now, futureDate);
  const myEmail = Session.getActiveUser().getEmail().toLowerCase();

  const processedIdsThisRun = new Set();

  events.forEach(event => {
    try {
      const uniqueId = event.isRecurringEvent() ? event.getEventSeries().getId() : event.getId();
      if (processedIdsThisRun.has(uniqueId)) {
        return;
      }

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
        if (!guestEmail.endsWith('@google.com') && !guestEmail.includes('resource.calendar.google.com') && !guestEmail.includes('group.calendar.google.com')) {
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

      // To ensure we only process events that triggered this execution,
      // we only look at events updated within the last 5 minutes.
      const fiveMinutesAgo = new Date(now.getTime() - (5 * 60 * 1000));
      if (event.getLastUpdated() < fiveMinutesAgo) {
        return;
      }

      // Passed all filters, mark as processed for this run to avoid recurring series spam
      processedIdsThisRun.add(uniqueId);

      const description = event.getDescription() || "";
      const workloadPrefix = (typeof ENV !== 'undefined' && ENV.WORKLOAD_LINK_PREFIX) 
        ? ENV.WORKLOAD_LINK_PREFIX 
        : (PropertiesService.getScriptProperties().getProperty('WORKLOAD_LINK_PREFIX') || "https://vector.lightning.force.com/lightning/r/Workload__c/");
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
        
        let note = "Awaiting Vector Workload ID.\n\n";
        note += "Please reply directly to this email with the Vector Workload link to confirm Alex's attendance.";
        
        if (creators && creators.length > 0) {
          const creatorsToEmail = creators.join(",");
          const subject = `Action Required: Missing Workload ID for "${event.getTitle()}"`;
          let body = `${note}\n\nEvent: ${event.getTitle()}\nDate: ${event.getStartTime()}`;
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
  // Delete existing triggers
  for (let i = 0; i < triggers.length; i++) {
    if (triggers[i].getHandlerFunction() === 'onCalendarInviteArrival' || triggers[i].getHandlerFunction() === 'scanCalendarAndRespond' || triggers[i].getHandlerFunction() === 'processWorkloadReplies') {
      ScriptApp.deleteTrigger(triggers[i]);
      console.log("Deleted old trigger.");
    }
  }
  
  ScriptApp.newTrigger('onCalendarInviteArrival')
      .forUserCalendar(Session.getActiveUser().getEmail())
      .onEventUpdated()
      .create();
      
  ScriptApp.newTrigger('processWorkloadReplies')
      .timeBased()
      .everyMinutes(15) // Check for email replies every 15 mins
      .create();
      
  console.log("Calendar event and Email processing triggers created successfully.");
}

function processWorkloadReplies() {
  const query = 'subject:"Action Required: Missing Workload ID for" is:unread';
  const threads = GmailApp.search(query, 0, 50);
  
  const workloadPrefix = (typeof ENV !== 'undefined' && ENV.WORKLOAD_LINK_PREFIX) 
    ? ENV.WORKLOAD_LINK_PREFIX 
    : (PropertiesService.getScriptProperties().getProperty('WORKLOAD_LINK_PREFIX') || "https://vector.lightning.force.com/lightning/r/Workload__c/");
    
  threads.forEach(thread => {
    const messages = thread.getMessages();
    let foundWorkload = false;
    let workloadLink = "";
    
    // Check all unread messages in the thread
    for (let i = 0; i < messages.length; i++) {
      const msg = messages[i];
      if (msg.isUnread()) {
        const body = msg.getPlainBody();
        // Regex to find the workload link
        const regex = new RegExp(workloadPrefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '[a-zA-Z0-9_]+');
        const match = body.match(regex);
        
        if (match) {
          foundWorkload = true;
          workloadLink = match[0];
          msg.markRead();
          break; // Stop after finding the first valid link in the thread
        }
      }
    }
    
    if (foundWorkload) {
      // Extract event title from subject: Action Required: Missing Workload ID for "Event Title"
      const subject = thread.getFirstMessageSubject();
      const titleMatch = subject.match(/"([^"]+)"/);
      
      if (titleMatch) {
        const eventTitle = titleMatch[1];
        updateEvent(eventTitle, workloadLink);
      }
    }
  });
}

function updateEvent(eventTitle, workloadLink) {
  // Find the event
  const now = new Date();
  const futureDate = new Date(now.getTime() + (30 * 24 * 60 * 60 * 1000));
  const events = CalendarApp.getDefaultCalendar().getEvents(now, futureDate, {search: eventTitle});
  
  if (events.length === 0) {
    console.log("Could not find event to update: " + eventTitle);
    return;
  }
  
  const event = events[0]; // Assuming the first match is correct
  
  // Update event description
  let desc = event.getDescription() || "";
  if (!desc.includes(workloadLink)) {
     event.setDescription(desc + "\n\nVector Workload: " + workloadLink);
  }
  event.setMyStatus(CalendarApp.GuestStatus.YES); // Accept the invite
}
