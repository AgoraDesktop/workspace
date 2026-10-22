/*
 * main_menu — the application's menu bar, CHECKED WITHOUT A COMPOSITOR.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **WHAT THIS CAN AND CANNOT SEE.** `-[NSApplication setMainMenu:]` builds the bar's WINDOW from the menu-bar
 * region the compositor sends, and with no compositor there is no region and no window — so what the desktop suite
 * has to measure (ink in the strip) cannot be measured here. What CAN be: the MENU ITSELF, which is built entirely
 * before any of that and is where every decision this component made lives — which menus there are, what is in the
 * application menu, which rows are wired and to WHAT, and what the shortcut masks say.
 *
 * **AND THE LAST GROUP IS THE ONE THAT WOULD OTHERWISE BE TAKEN ON TRUST.** `-update` is the walk that decides
 * whether a row is enabled, and this tree's rule is that an enabled row whose action nobody answers is a promise
 * the menu cannot keep. So the test runs the walk and checks the OUTCOME: the application menu's rows are live; in
 * File/View/Go every row but W2's New Workspace Window is greyed; and "Bring All to Front" — the one Window row with
 * a target — is.
 */
#import <AppKit/NSApplication.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSEvent.h>
#import <Foundation/Foundation.h>

#import "WSMainMenu.h"

#include <stdio.h>

static int failed;

static void check(BOOL condition, const char *name)
{
	printf("  [%s] %s\n", condition ? "ok" : "FAIL", name);
	if (!condition) failed++;
}

/* **A TARGET THAT ANSWERS THE TWO ROWS THE APPKIT REFUSES.** The bar's application menu names this object for About
 * and Preferences, and the walk below enables a row exactly when its target answers its action — so the target has
 * to exist for "About is live" to be a claim about the menu rather than about nothing. */
@interface WSMenuTestTarget : NSObject
- (void)orderFrontAboutPanel:(id)sender;
- (void)showPreferences:(id)sender;
/* W2's File > New Workspace Window is the one row in the five menus with a target: the application owns the
 * second window, so the test's stand-in answers it too and the enabling walk can be measured. */
- (void)newWorkspaceWindow:(id)sender;
/* **AND `File > Print…` IS THE SECOND ROW WITH AN OWNER**, the file window's: a stand-in that answers it is what makes
 * "the print row is live" a claim about the menu rather than about nothing. */
- (void)printSelection:(id)sender;
@end

@implementation WSMenuTestTarget

- (void)orderFrontAboutPanel:(id)sender { (void)sender; }
- (void)showPreferences:(id)sender { (void)sender; }
- (void)newWorkspaceWindow:(id)sender { (void)sender; }
- (void)printSelection:(id)sender { (void)sender; }

@end

static NSMenuItem *itemTitled(NSMenu *menu, NSString *title)
{
	NSInteger i;

	for (i = 0; i < [menu numberOfItems]; i++) {
		NSMenuItem *item = [menu itemAtIndex:i];

		if ([[item title] isEqualToString:title]) {
			return item;
		}
	}
	return nil;
}

static NSInteger indexTitled(NSMenu *menu, NSString *title)
{
	NSInteger i;

	for (i = 0; i < [menu numberOfItems]; i++) {
		if ([[[menu itemAtIndex:i] title] isEqualToString:title]) {
			return i;
		}
	}
	return NSNotFound;
}

int main(void)
{
	@autoreleasepool {
		NSApplication *application = [NSApplication sharedApplication];
		WSMenuTestTarget *target = [[WSMenuTestTarget alloc] init];
		NSString *name = [[NSProcessInfo processInfo] processName];
		NSMenu *bar;
		NSMenu *appMenu;
		NSMenuItem *item;
		NSInteger i;

		[WSMainMenu installWithTarget:target];
		bar = (NSMenu *)[application mainMenu];

		/* 1. THE BAR ITSELF, AND THE TWO RULES THE APPKIT OWNS. */
		check(bar != nil, "the application HAS a main menu after the install");
		check(bar != nil && [bar numberOfItems] == 7, "and it has seven menus: the application's own and five more");
		check(bar != nil && [[[bar itemAtIndex:0] title] isEqualToString:name],
		      "the FIRST menu is the application's own, named after the process");
		check(bar != nil && [bar numberOfItems] > 0 &&
		      [[[bar itemAtIndex:[bar numberOfItems] - 1] title] isEqualToString:@"Help"],
		      "and HELP is LAST, wherever it was put");

		check(bar != nil && indexTitled(bar, @"File") == 1, "File is the second menu");
		check(bar != nil && indexTitled(bar, @"Edit") == 2, "Edit the third");
		check(bar != nil && indexTitled(bar, @"View") == 3, "View the fourth");
		check(bar != nil && indexTitled(bar, @"Go") == 4, "Go the fifth");
		check(bar != nil && indexTitled(bar, @"Window") == 5, "and Window the sixth");

		/* 2. THE APPLICATION MENU'S CONTENTS — THE FOUR THINGS EVERY MAC APPLICATION HAS. */
		appMenu = (bar != nil && [bar numberOfItems] > 0) ? (NSMenu *)[[bar itemAtIndex:0] submenu] : nil;
		check(appMenu != nil, "the application menu HAS a submenu");
		check(itemTitled(appMenu, [NSString stringWithFormat:@"About %@", name]) != nil,
		      "it offers \"About <application>\"");
		check(itemTitled(appMenu, @"Preferences…") != nil, "and \"Preferences…\"");
		check(itemTitled(appMenu, @"Services") != nil, "and a Services submenu");
		check(itemTitled(appMenu, [NSString stringWithFormat:@"Hide %@", name]) != nil, "and \"Hide <application>\"");
		check(itemTitled(appMenu, @"Hide Others") != nil, "and \"Hide Others\"");
		check(itemTitled(appMenu, @"Show All") != nil, "and \"Show All\"");
		check(itemTitled(appMenu, [NSString stringWithFormat:@"Quit %@", name]) != nil,
		      "and \"Quit <application>\"");
		check([itemTitled(appMenu, @"Services") submenu] != nil, "the Services row carries a menu");

		/* **AND NOTHING IN THE BAR NAMES ANOTHER APPLICATION'S PRODUCT.** Agora's file manager is Workspace, so
		 * the File menu's first row is "New Workspace Window" — the Mac's own pattern for this row is
		 * "New <application> Window", and naming another file manager instead was this file copying Apple's STRING along
		 * with Apple's SHAPE. Checked over the whole tree, because the row that is wrong is rarely the only one. */
		{
			NSArray *menus = [bar itemArray];
			NSUInteger m, k;
			BOOL mentionsAppleShellName = NO;
			NSInteger inspected = 0;

			for (m = 0; m < [menus count]; m++) {
				NSMenu *submenu = (NSMenu *)[[menus objectAtIndex:m] submenu];

				for (k = 0; k < (NSUInteger)[submenu numberOfItems]; k++) {
					NSString *title = [[submenu itemAtIndex:(NSInteger)k] title];

					inspected++;
					/* **THE LITERAL IS THE SUBJECT OF THE CHECK, NOT A NAME OF OURS.** It is the third-party
					 * product name this assertion exists to keep out of every menu row; nothing here is named
					 * after it. */
					if ([title rangeOfString:@"Finder"].location != NSNotFound) {
						mentionsAppleShellName = YES;
						printf("  (note: \"%s\" in the %s menu)\n", [title UTF8String],
						       [[[menus objectAtIndex:m] title] UTF8String]);
					}
				}
			}
			check(inspected > 20, "the whole bar is walked");
			check(!mentionsAppleShellName, "and NO menu row names another file manager — this application is Workspace");
		}

		/* 3. WHERE EACH OF THEM GOES, WHICH IS THE PART A PICTURE CANNOT SHOW. */
		item = itemTitled(appMenu, [NSString stringWithFormat:@"About %@", name]);
		check(item != nil && [item target] == target && [item action] == @selector(orderFrontAboutPanel:),
		      "About is sent to the application's own door, not the AppKit's refusal");

		item = itemTitled(appMenu, @"Preferences…");
		check(item != nil && [item target] == target && [item action] == @selector(showPreferences:),
		      "and Preferences to the application's");
		check(item != nil && [[item keyEquivalent] isEqualToString:@","] &&
		      ([item keyEquivalentModifierMask] & NSCommandKeyMask) != 0,
		      "with Command-, as its shortcut");

		item = itemTitled(appMenu, [NSString stringWithFormat:@"Quit %@", name]);
		check(item != nil && [item target] == application && [item action] == @selector(terminate:),
		      "Quit goes to the application's own -terminate:");

		/* **THE MASK IS THE POINT OF THIS ONE.** Apple's item defaults to `NSCommandKeyMask`; this tier's leaves
		 * it at ZERO, so a row built by the convenience factory and left alone would answer a BARE `q`. The walk
		 * in `NSMenu -performKeyEquivalent:` compares the item's masked bits against the event's, so the check is
		 * the mask and not a comment. */
		check(item != nil && [[item keyEquivalent] isEqualToString:@"q"] &&
		      ([item keyEquivalentModifierMask] & NSCommandKeyMask) != 0,
		      "and its shortcut is COMMAND-Q, not a bare q");

		item = itemTitled(appMenu, @"Hide Others");
		check(item != nil && ([item keyEquivalentModifierMask] & NSCommandKeyMask) != 0 &&
		      ([item keyEquivalentModifierMask] & NSAlternateKeyMask) != 0,
		      "Hide Others is Command-Option-H");

		item = itemTitled(appMenu, @"Show All");
		check(item != nil && [[item keyEquivalent] length] == 0, "and Show All has no shortcut at all");

		/* 4. WHAT THE ENABLING WALK MAKES OF IT — RUN, NOT ASSUMED. */
		[bar update];

		item = itemTitled(appMenu, [NSString stringWithFormat:@"About %@", name]);
		check(item != nil && [item isEnabled], "About is ENABLED: its target answers its action");
		item = itemTitled(appMenu, @"Preferences…");
		check(item != nil && [item isEnabled], "Preferences is enabled for the same reason");
		item = itemTitled(appMenu, [NSString stringWithFormat:@"Quit %@", name]);
		check(item != nil && [item isEnabled], "Quit is enabled");
		item = itemTitled([itemTitled(appMenu, @"Services") submenu], @"No Services Apply");
		check(item != nil && ![item isEnabled], "the Services placeholder is DISABLED, because nothing answers it");

		/* **THE ONE ROW W2 LIGHTS.** It is the application's target, and the walk can see that it answers. */
		item = itemTitled([itemTitled(bar, @"File") submenu], @"New Workspace Window");
		check(item != nil && [item target] == target && [item action] == @selector(newWorkspaceWindow:),
		      "New Workspace Window is the application's own row");
		check(item != nil && [item isEnabled], "and it is ENABLED, because the application answers it");

		/* **AND THE SECOND ROW WITH AN OWNER SINCE THE PRINT SYSTEM LANDED**: the file window's `-printSelection:`. */
		item = itemTitled([itemTitled(bar, @"File") submenu], @"Print…");
		check(item != nil && [item target] == target && [item action] == @selector(printSelection:),
		      "File > Print… is the file window's row, through the chain");
		check(item != nil && [item isEnabled], "and it is ENABLED, because the stand-in answers it");
		check(item != nil && [[item keyEquivalent] isEqual:@"p"], "and it carries Cmd-P");

		/* AND THE MENUS BESIDE IT ARE A SKELETON: every row names the reference file manager's own selector and none of them has a
		 * target until the stage that implements it exists. Greyed is the honest state — an enabled row nobody
		 * answers is a promise the menu cannot keep. */
		{
			NSArray *skeletons = [NSArray arrayWithObjects:@"File", @"View", @"Go", nil];
			NSUInteger s;
			BOOL allDisabled = YES;
			NSInteger inspected = 0;

			for (s = 0; s < [skeletons count]; s++) {
				NSMenu *menu = (NSMenu *)[[bar itemAtIndex:indexTitled(bar, [skeletons objectAtIndex:s])]
							 submenu];

				for (i = 0; i < [menu numberOfItems]; i++) {
					NSMenuItem *row = [menu itemAtIndex:i];

					if ([row isSeparatorItem]) {
						continue;
					}
					/* NEW WORKSPACE WINDOW IS W2'S AND PRINT IS THE PRINT SYSTEM'S; both are checked above, and
					 * every other row here still waits for its stage and must be grey. */
					if ([row action] == @selector(newWorkspaceWindow:)
					    || [row action] == @selector(printSelection:)) {
						continue;
					}
					inspected++;
					if ([row isEnabled]) {
						allDisabled = NO;
					}
				}
			}
			check(inspected > 10, "the File, View and Go menus are populated");
			check(allDisabled, "and every OTHER row in them is disabled, because its feature is not written yet");
		}

		/* **AND THE EXCEPTION, WHICH IS MEASURED RATHER THAN WISHED AWAY.** The Edit menu's five chain-routed rows
		 * come out ENABLED and nothing in Workspace answers them. THE CAUSE IS THIS TIER'S `NSResponder`, NOT THE
		 * MENU: it implements `-cut:`, `-copy:`, `-paste:`, `-delete:` and `-selectAll:` in the BASE, as forwarders
		 * to the next responder, where Apple leaves a plain view responding to none of them — so the walk's
		 * `-targetForAction:` finds an answer at EVERY responder and enables the row. Apple's own Copy is disabled
		 * with no text view focused. The gap is recorded in `PROVENANCE.md`, and these checks PIN it: the day the
		 * walk learns to skip a base forwarder, this is where the change shows up. */
		{
			NSArray *routed = [NSArray arrayWithObjects:@"Cut", @"Copy", @"Paste", @"Delete", @"Select All", nil];
			NSMenu *edit = (NSMenu *)[[bar itemAtIndex:indexTitled(bar, @"Edit")] submenu];
			NSUInteger r;
			BOOL allEnabled = YES;

			for (r = 0; r < [routed count]; r++) {
				NSMenuItem *row = itemTitled(edit, [routed objectAtIndex:r]);

				if (row == nil || ![row isEnabled]) {
					allEnabled = NO;
				}
			}
			check([edit numberOfItems] > 5, "the Edit menu is populated");
			check(allEnabled, "its five chain-routed rows are ENABLED by the base responder's own forwarders");
			item = itemTitled(edit, @"Undo");
			check(item != nil && ![item isEnabled], "while Undo, which no responder forwards, stays disabled");
		}

		/* AND THE ONE WINDOW ROW WITH A TARGET, which the walk must therefore leave live. */
		{
			NSMenu *windowMenu = (NSMenu *)[[bar itemAtIndex:indexTitled(bar, @"Window")] submenu];

			item = itemTitled(windowMenu, @"Bring All to Front");
			check(item != nil && [item isEnabled], "\"Bring All to Front\" IS enabled: -arrangeInFront: is answered");
			item = itemTitled(windowMenu, @"Minimize");
			check(item != nil && ![item isEnabled], "and Minimize is not — the desktop is never the key window");
		}

		printf("main_menu: %d case(s) failed\n", failed);
		[target release];
	}
	return failed == 0 ? 0 : 1;
}
