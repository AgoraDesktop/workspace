/*
 * WSMainMenu.h — the application's menu bar: WHICH menus and WHAT is in them.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **WHERE THE LINE IS.** The AppKit owns the MECHANISM and this file owns the CONTENTS. `-[NSApplication
 * setMainMenu:]` takes a menu, puts the APPLICATION'S OWN menu at its front — named after the process, because the
 * AppKit owns that rule — moves Help to the back, and builds the borderless window at `NSMainMenuWindowLevel`
 * whose `NSMenuView` draws the titles and opens one on a click. What it cannot know is which menus a Mac file
 * manager has and what is in them; that is a decision per application, and it is this file. See `DESIGN.md`.
 *
 * **EVERY ROW WITH A SHORTCUT NAMES ITS OWN MODIFIER MASK**, and why is in the header of the implementation: this
 * tier's `-[NSMenuItem initWithTitle:action:keyEquivalent:]` leaves the mask at ZERO where Apple's sets
 * `NSCommandKeyMask`, so a row built with the convenience factory would answer a BARE keystroke. The deviation is
 * the AppKit's and is recorded in `PROVENANCE.md`; what a caller must do meanwhile is say what it means.
 */
#ifndef WORKSPACE_WSMAINMENU_H
#define WORKSPACE_WSMAINMENU_H

#import <Foundation/NSObject.h>

@interface WSMainMenu : NSObject

/* **BUILD THE BAR AND INSTALL IT.** `target` answers `-orderFrontAboutPanel:` and `-showPreferences:` — the two
 * application-menu rows whose mechanism is the application's rather than the AppKit's, the AppKit's own
 * `-[NSApplication orderFrontStandardAboutPanel:]` being a named refusal. It is NOT retained, which is Apple's
 * contract for a menu item's target and the reason the application must outlive its bar. */
+ (void)installWithTarget:(id)target;

@end

#endif /* WORKSPACE_WSMAINMENU_H */
