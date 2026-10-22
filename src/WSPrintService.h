/*
 * WSPrintService.h — PRINTING A LIST OF FILES, WHICH IS THE ONE THING A FILE MANAGER CAN PRINT.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * **THIS IS THE BODY BEHIND BOTH DOORS.** `-application:printFiles:withSettings:showPrintPanels:` is the launch's door
 * (NSApplication asks the delegate), and `File > Print…` is the app's own; neither should own a renderer, so both reach
 * this class. One print view per path (`WSPrintView`), one operation per view, the settings merged into a COPY of the
 * shared ticket so a print request cannot change the application's default paper.
 *
 * **THE REPLY IS THE LAUNCH'S THREE-VALUED ONE**, and the order matters: a cancel anywhere means the request was
 * cancelled (a person who cancels the second of three documents does not want "success"), otherwise success when at
 * least one document printed, and failure when none did.
 */
#ifndef WORKSPACE_WSPRINTSERVICE_H
#define WORKSPACE_WSPRINTSERVICE_H

#import <AppKit/NSApplication.h>

@class NSArray;
@class NSDictionary;

@interface WSPrintService : NSObject

/* `settings` is Apple's print-settings dictionary (`NSPrintJobDisposition`, `NSPrintSavePath`, …) merged over the shared
 * ticket; nil means "as the shared ticket says". `showPrintPanels` is the ticket's own switch: a request that arrives
 * with NO wants the job to run, not a dialog. */
+ (NSApplicationPrintReply)printFiles:(NSArray *)paths
			     settings:(NSDictionary *)settings
		      showPrintPanels:(BOOL)showPrintPanels;

@end

#endif /* WORKSPACE_WSPRINTSERVICE_H */
