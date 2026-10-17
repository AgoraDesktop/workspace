/*
 * WSMainMenu.m — the menu bar's contents: the application menu and the five menus beside it.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **THE APPLICATION MENU IS NOT BUILT HERE, AND THAT IS THE FIRST THING TO KNOW.** `-[NSApplication setMainMenu:]`
 * INSERTS it — at index 0, titled with `-[NSProcessInfo processName]` — and moves Help last, because those two
 * rules are the HIG's and belong to the framework rather than to each application. So this file builds the five
 * menus an application writes, installs the bar, and then fills the application menu the install just made. Filling
 * it first would mean naming it here, and a second copy of "what is this application called" is how a bar comes to
 * read `Finder` above `Quit Workspace`. (The mechanism is `-cg_arrangeMenuBar` in `NSApplication.m`.)
 *
 * **A ROW WITH NO TARGET IS A DISABLED ROW, AND THAT IS THE DESIGN RATHER THAN AN OMISSION.** `-[NSMenu update]`
 * walks every item before a menu tracks and sets `[item setEnabled:([item action] != NULL && [target
 * respondsToSelector:[item action]])]`. A row whose feature has not been written yet therefore has no target, is
 * found not to answer, and is DRAWN GREY — which is exactly how a Mac application shows a command it cannot offer
 * right now, and how this bar says what Workspace can actually do instead of being a picture of the Finder. Each
 * later stage lights up its own rows by giving him a target; nothing here changes.
 *
 * **EVERY SHORTCUT NAMES ITS OWN MASK.** This tier's `-[NSMenuItem initWithTitle:action:keyEquivalent:]` sets the
 * title, the action and the key string and leaves `_keyEquivalentModifierMask` at ZERO, where Apple's sets
 * `NSCommandKeyMask` — so a row built with the convenience factory and left alone would match a BARE `q`. MEASURED
 * in `NSMenu -performKeyEquivalent:`, which compares the item's masked bits against the event's: with the mask at
 * zero, Command-Q does NOT match and plain `q` DOES. See `PROVENANCE.md`; here it means `WSRow` always says.
 */
#import "WSMainMenu.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSString.h>

/* **THE APPLICATION'S NAME, AS THE BAR WILL SPELL IT.** The application menu's TITLE is the AppKit's to set, from
 * `-[NSProcessInfo processName]`; the rows INSIDE it — "Hide Workspace", "Quit Workspace" — take their name from
 * the same door rather than from the bundle, so the title and its contents cannot come to disagree. */
static NSString *WSApplicationName(void)
{
	NSString *name = [[NSProcessInfo processInfo] processName];

	return (name != nil && [name length] > 0) ? name : @"Application";
}

/* A TOP-LEVEL TITLE: an item whose whole content is a submenu. A BAR'S TITLES ARE MENUS; the leaf rows are what is
 * inside them — the mistake `libagora-app/tests/appkit_menu_draw.m` records making with four bare titles. */
static NSMenuItem *WSBarTitle(NSString *title, NSMenu *submenu)
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];

	[item setSubmenu:submenu];
	return [item autorelease];
}

/* ONE ROW. `key` nil means NO key equivalent — and then the mask is set to zero as well, so that an empty key
 * string can never be matched by an event that happens to carry the mask. */
static NSMenuItem *WSRow(NSMenu *menu, NSString *title, SEL action, id target, NSString *key, NSUInteger mask)
{
	NSMenuItem *item = [menu addItemWithTitle:title
					   action:action
				    keyEquivalent:(key != nil) ? key : @""];

	[item setTarget:target];
	[item setKeyEquivalentModifierMask:((key != nil) && [key length] > 0) ? mask : 0];
	return item;
}

/* AND THE ONE SHORTCUT THAT IS NOT A CHARACTER: ⌘↑, whose key equivalent is the UP ARROW function key — a single
 * code point in the Private Use Area, which is how every Cocoa program spells it. */
static NSString *WSUpArrowKeyEquivalent(void)
{
	return @"\uf700";
}

/* ---------------------------------------------------------------------------------------------------
 * THE APPLICATION MENU — filled AFTER the install, because the install is what makes it.
 * --------------------------------------------------------------------------------------------------- */

static void WSFillApplicationMenu(NSMenu *menu, id target)
{
	NSApplication *application = [NSApplication sharedApplication];
	NSString *name = WSApplicationName();
	NSMenu *services;

	WSRow(menu, [NSString stringWithFormat:@"About %@", name], @selector(orderFrontAboutPanel:), target, nil, 0);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Preferences…", @selector(showPreferences:), target, @",", NSCommandKeyMask);
	[menu addItem:[NSMenuItem separatorItem]];

	/* **SERVICES IS A SUBMENU WITH ONE ROW THAT SAYS WHY IT IS EMPTY.** On the Mac the system fills it from the
	 * applications that have registered; this tier has no services registry (it is W13's, with the provider that
	 * would register Workspace's own), so the honest menu is one that says so rather than one that is missing —
	 * and a row with no action is disabled by the same walk as every other unavailable command. */
	services = [[NSMenu alloc] initWithTitle:@"Services"];
	WSRow(services, @"No Services Apply", NULL, nil, nil, 0);
	[menu addItem:WSBarTitle(@"Services", services)];
	[services release];

	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, [NSString stringWithFormat:@"Hide %@", name], @selector(hide:), application, @"h", NSCommandKeyMask);
	WSRow(menu, @"Hide Others", @selector(hideOtherApplications:), application, @"h",
	      NSCommandKeyMask | NSAlternateKeyMask);
	WSRow(menu, @"Show All", @selector(unhideAllApplications:), application, nil, 0);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, [NSString stringWithFormat:@"Quit %@", name], @selector(terminate:), application, @"q",
	      NSCommandKeyMask);
}

/* ---------------------------------------------------------------------------------------------------
 * THE FIVE BESIDE IT. Nothing here invents a command: each row names the selector the Finder's own row sends, and
 * the target is nil until the stage that answers it exists.
 * --------------------------------------------------------------------------------------------------- */

static NSMenu *WSFileMenu(void)
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"File"] autorelease];

	WSRow(menu, @"New Finder Window", @selector(newFinderWindow:), nil, @"n", NSCommandKeyMask);
	WSRow(menu, @"New Folder", @selector(newFolder:), nil, @"n", NSCommandKeyMask | NSShiftKeyMask);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Open", @selector(openDocument:), nil, @"o", NSCommandKeyMask);
	WSRow(menu, @"Close Window", @selector(performClose:), nil, @"w", NSCommandKeyMask);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Get Info", @selector(getInfo:), nil, @"i", NSCommandKeyMask);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Move to Trash", @selector(moveToTrash:), nil, @"\u232b", NSCommandKeyMask);
	return menu;
}

static NSMenu *WSEditMenu(void)
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];

	WSRow(menu, @"Undo", @selector(undo:), nil, @"z", NSCommandKeyMask);
	WSRow(menu, @"Redo", @selector(redo:), nil, @"z", NSCommandKeyMask | NSShiftKeyMask);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Cut", @selector(cut:), nil, @"x", NSCommandKeyMask);
	WSRow(menu, @"Copy", @selector(copy:), nil, @"c", NSCommandKeyMask);
	WSRow(menu, @"Paste", @selector(paste:), nil, @"v", NSCommandKeyMask);
	WSRow(menu, @"Delete", @selector(delete:), nil, nil, 0);
	WSRow(menu, @"Select All", @selector(selectAll:), nil, @"a", NSCommandKeyMask);
	return menu;
}

static NSMenu *WSViewMenu(void)
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"View"] autorelease];

	WSRow(menu, @"as Icons", @selector(cg_useIconView:), nil, @"1", NSCommandKeyMask);
	WSRow(menu, @"as List", @selector(cg_useListView:), nil, @"2", NSCommandKeyMask);
	WSRow(menu, @"as Columns", @selector(cg_useColumnView:), nil, @"3", NSCommandKeyMask);
	WSRow(menu, @"as Cover Flow", @selector(cg_useCoverFlowView:), nil, @"4", NSCommandKeyMask);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Show Toolbar", @selector(toggleToolbarShown:), nil, @"t", NSCommandKeyMask | NSAlternateKeyMask);
	WSRow(menu, @"Customize Toolbar…", @selector(runToolbarCustomizationPalette:), nil, nil, 0);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Show View Options", @selector(showViewOptions:), nil, @"j", NSCommandKeyMask);
	return menu;
}

static NSMenu *WSGoMenu(void)
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Go"] autorelease];

	WSRow(menu, @"Back", @selector(goBack:), nil, @"[", NSCommandKeyMask);
	WSRow(menu, @"Forward", @selector(goForward:), nil, @"]", NSCommandKeyMask);
	WSRow(menu, @"Enclosing Folder", @selector(goToEnclosingFolder:), nil, WSUpArrowKeyEquivalent(), NSCommandKeyMask);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Computer", @selector(goToComputer:), nil, @"c", NSCommandKeyMask | NSShiftKeyMask);
	WSRow(menu, @"Home", @selector(goHome:), nil, @"h", NSCommandKeyMask | NSShiftKeyMask);
	WSRow(menu, @"Desktop", @selector(goToDesktop:), nil, @"d", NSCommandKeyMask | NSShiftKeyMask);
	WSRow(menu, @"Applications", @selector(goToApplications:), nil, @"a", NSCommandKeyMask | NSShiftKeyMask);
	WSRow(menu, @"Utilities", @selector(goToUtilities:), nil, @"u", NSCommandKeyMask | NSShiftKeyMask);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Connect to Server…", @selector(connectToServer:), nil, @"k", NSCommandKeyMask);
	return menu;
}

/* **THE ONE WINDOW ROW THAT IS ENABLED TODAY.** "Bring All to Front" is a question about the APPLICATION, and
 * `-[NSApplication arrangeInFront:]` answers it; Minimize and Zoom are questions about the KEY WINDOW, which this
 * desktop never is — it is `canBecomeKeyWindow` NO — so the responder chain has nothing to give them and the walk
 * greys them correctly. */
static NSMenu *WSWindowMenu(void)
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];

	WSRow(menu, @"Minimize", @selector(performMiniaturize:), nil, @"m", NSCommandKeyMask);
	WSRow(menu, @"Zoom", @selector(performZoom:), nil, nil, 0);
	[menu addItem:[NSMenuItem separatorItem]];
	WSRow(menu, @"Bring All to Front", @selector(arrangeInFront:), [NSApplication sharedApplication], nil, 0);
	return menu;
}

static NSMenu *WSHelpMenu(void)
{
	NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Help"] autorelease];

	WSRow(menu, @"Workspace Help", @selector(showHelp:), nil, @"?", NSCommandKeyMask);
	return menu;
}

@implementation WSMainMenu

+ (void)installWithTarget:(id)target
{
	NSApplication *application = [NSApplication sharedApplication];
	NSMenu *bar = [[NSMenu alloc] initWithTitle:@"MainMenu"];

	[bar addItem:WSBarTitle(@"File", WSFileMenu())];
	[bar addItem:WSBarTitle(@"Edit", WSEditMenu())];
	[bar addItem:WSBarTitle(@"View", WSViewMenu())];
	[bar addItem:WSBarTitle(@"Go", WSGoMenu())];
	[bar addItem:WSBarTitle(@"Window", WSWindowMenu())];
	[bar addItem:WSBarTitle(@"Help", WSHelpMenu())];

	/* **INSTALL FIRST, FILL THE APPLICATION MENU SECOND, AND THE ORDER IS THE POINT.** `-setMainMenu:` is what
	 * INSERTS the application's own menu at index 0, so the submenu this file has to fill does not exist until that
	 * call has returned. */
	[application setMainMenu:bar];
	WSFillApplicationMenu([[bar itemAtIndex:0] submenu], target);
	[bar release];
}

@end
