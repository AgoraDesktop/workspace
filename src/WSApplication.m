/*
 * WSApplication.m — create the desktop, put it on the screen, pump.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSApplication.h"

#import "WSAboutPanel.h"
#import "WSDesktopView.h"
#import "WSDesktopWindow.h"
#import "WSFileWindowController.h"
#import "WSIconView.h"
#import "WSPlaces.h"
#import "WSMainMenu.h"
#import "WSPreferencesWindow.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSScreen.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSString.h>

#include <stdio.h>
#include <stdlib.h>

/* **THE DEADLINE, WHICH IS A DELEGATE BECAUSE THE LOOP ANNOUNCES ITS OWN PASSES.** `-[NSApplication run]` posts
 * `NSApplicationWillUpdate`/`DidUpdate` to its delegate once per pass — "a place to change what is shown BETWEEN
 * passes", which is Apple's own reason for the pair — and that is exactly where a bounded run belongs: the flag
 * `-[NSApplication stop:]` sets is read at the top of the loop, so setting it from the pass that passes the
 * deadline ends the loop within a frame. */
@interface WSRunDeadline : NSObject
{
	NSDate *_deadline;
	NSUInteger _passes;
}
- (instancetype)initWithSeconds:(double)seconds;
- (NSUInteger)passes;
- (void)applicationDidUpdate:(NSNotification *)notification;
@end

@implementation WSRunDeadline

- (instancetype)initWithSeconds:(double)seconds
{
	self = [super init];
	if (self != nil) {
		_deadline = [[NSDate dateWithTimeIntervalSinceNow:seconds] retain];
	}
	return self;
}

- (void)dealloc
{
	[_deadline release];
	[super dealloc];
}

- (NSUInteger)passes { return _passes; }

- (void)applicationDidUpdate:(NSNotification *)notification
{
	(void)notification;
	_passes++;
	if ([_deadline timeIntervalSinceNow] <= 0.0) {
		[[NSApplication sharedApplication] stop:nil];
	}
}

@end

@interface WSApplication ()
- (void)iconViewRequestFolderWindow:(NSNotification *)notification;
- (void)openFileWindowAtDirectory:(NSString *)directory;
- (void)desktopOpenFolder:(NSNotification *)notification;
- (void)fileWindowWillClose:(NSNotification *)notification;
@end

@implementation WSApplication

- (instancetype)init
{
	self = [super init];
	if (self != nil) {
		_fileWindows = [[NSMutableArray alloc] init];
	}
	return self;
}

/* WHICH DIRECTORY IS THE DESKTOP. `~/Desktop`, or `AGORA_DESKTOP` when it is set — the door the suite uses to
 * point a desktop at a directory it controls. A shell session names the real one; W1 does not yet have a
 * preferences system to name it any other way. */
+ (NSString *)desktopDirectory
{
	return [WSPlaces desktopDirectory];
}

- (BOOL)start
{
	NSApplication *application = [NSApplication sharedApplication];
	NSScreen *screen = [NSScreen mainScreen];
	NSString *directory = [WSApplication desktopDirectory];

	_desktop = [[WSDesktopWindow alloc] initWithScreen:screen directory:directory];
	if (_desktop == nil) {
		return NO;
	}
	[_desktop orderFront:nil];

	/* **THE MENU BAR, WHICH IS THE APPLICATION'S OWN.** `WSMainMenu` builds the five menus an application writes and
	 * installs the bar, and the AppKit inserts the application menu it makes room for; THIS object is the target of
	 * the two rows the AppKit refuses — About and Preferences. */
	[WSMainMenu installWithTarget:self];

	/* **A FOLDER FROM THE DESKTOP IS A WINDOW REQUEST.** The desktop view posts; this object is the only one that
	 * knows what a file window is. */
	[[NSNotificationCenter defaultCenter] addObserver:self
		selector:@selector(desktopOpenFolder:)
		name:WSDesktopViewOpenFolderNotification object:nil];

	/* **A SPRING-LOADED FOLDER IS THE SAME REQUEST.** Hovering a folder icon long enough is the icon view's way of
	 * asking for the folder's window; the application is still the only object that makes one. */
	[[NSNotificationCenter defaultCenter] addObserver:self
		selector:@selector(iconViewRequestFolderWindow:)
		name:WSIconViewRequestFolderWindowNotification object:nil];

	/* **AND THE ABOUT PANEL, WHEN THE TEST'S DOOR ASKED FOR IT.** Opening it from here is the same window, the
	 * same chrome and the same activation a menu action would cause — which is the point: a probe cannot click. */
	if (_showsAboutOnStart) {
		[self orderFrontAboutPanel:nil];
	}
	if (_showsFileWindowOnStart) {
		[self newWorkspaceWindow:nil];
	}

	fprintf(stderr, "workspace: desktop window at level %ld, frame %gx%g at (%g,%g), showing %s\n",
		(long)[_desktop level], (double)[_desktop frame].size.width, (double)[_desktop frame].size.height,
		(double)[_desktop frame].origin.x, (double)[_desktop frame].origin.y, [directory UTF8String]);
	return YES;
}

/* **THE ORDINARY RUN LOOP, AND IT TOOK A MENU BAR TO GET HERE.** W0 pumped its own events, which was enough for a
 * desktop that only had to stay on the screen — but a menu opened from the bar is DRIVEN BY THE APPLICATION'S OWN
 * LOOP. `NSMenuView -mouseDown:` begins the session and then fetches each next event only while
 * `-[NSApplication isRunning]`, a deliberately narrow gate whose other half is `-cg_connectionIsGone`; an
 * application that pumps by hand is therefore NOT running, and gets a menu that is begun and never driven — it
 * cannot be picked, dismissed, or moved to another title. MEASURED, in the live scene: the AppKit's own
 * `APPKIT_MENU_DIAG` printed `the menu is on screen now` and then not one line of the loop that would have handled
 * the click that followed.
 *
 * SO THE GATE IS NOT WRONG — THE PROXY WAS. `-isRunning` answers "is the application in its run loop", and it is
 * true the moment this door uses the loop the AppKit names instead of one of its own. The deadline is enforced
 * from the loop's own per-pass notification, so `--seconds` survives; the desktop's events, its windows and its
 * frame pacing are now the AppKit's, which is what the plan always said W0's pump was standing in for. */
- (void)runForSeconds:(double)seconds
{
	NSApplication *application = [NSApplication sharedApplication];
	WSRunDeadline *deadline = [[WSRunDeadline alloc] initWithSeconds:seconds];

	[application setDelegate:deadline];
	[application run];
	[application setDelegate:nil];
	fprintf(stderr, "workspace: ran %lu loop pass(es)\n", (unsigned long)[deadline passes]);
	[deadline release];
}

- (void)stop
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	while ([_fileWindows count] > 0) {
		WSFileWindowController *controller = [[_fileWindows lastObject] retain];

		[_fileWindows removeLastObject];
		[controller close];
		[controller release];
	}
	[_preferences release];
	_preferences = nil;
	[_desktop close];
	[_desktop release];
	_desktop = nil;
}

- (void)setShowsFileWindowOnStart:(BOOL)flag
{
	_showsFileWindowOnStart = flag;
}

- (void)setFileWindowUsesListView:(BOOL)flag
{
	/* **A FALSE FLAG MEANS "NOT THIS MODE", NOT "RESET TO ICONS".** `main` calls both setters in a fixed
	 * order and passes NO for the one it did not ask for, so an unconditional assignment in either one
	 * erased the other: `--list-view` set 1 here and the column setter's `flag ? 2 : 0` put it back to 0,
	 * which is why the test's door opened an icon window. MEASURED on the demo's file window. */
	if (flag) {
		_fileWindowViewMode = 1;
	}
}

- (void)setFileWindowUsesColumnView:(BOOL)flag
{
	if (flag) {
		_fileWindowViewMode = 2;
	}
}

/* **ONE FOLDER, ONE WINDOW, ONE MODEL.** The controller owns its own history and path bar; the application owns
 * the list of them and is the thing a close notification removes one from. */
- (void)openFileWindowAtDirectory:(NSString *)directory
{
	WSFileWindowController *controller = [[WSFileWindowController alloc] initWithDirectory:directory];

	if (controller == nil) {
		return;
	}
	[_fileWindows addObject:controller];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(fileWindowWillClose:)
		name:NSWindowWillCloseNotification object:[controller window]];
	if (_fileWindowViewMode != 0) {
		[controller setViewMode:_fileWindowViewMode];
	}
	[controller showWindow:nil];
	fprintf(stderr, "workspace: file window for %s\n", [directory UTF8String]);
	[controller release];
}

- (void)newWorkspaceWindow:(id)sender
{
	(void)sender;
	[self openFileWindowAtDirectory:[WSPlaces desktopDirectory]];
}

- (void)desktopOpenFolder:(NSNotification *)notification
{
	NSString *path = [[notification userInfo] objectForKey:WSDesktopViewPathKey];

	if (path != nil) {
		[self openFileWindowAtDirectory:path];
	}
}

- (void)iconViewRequestFolderWindow:(NSNotification *)notification
{
	NSString *path = [[notification userInfo] objectForKey:WSIconViewFolderPathKey];

	if (path != nil) {
		[self openFileWindowAtDirectory:path];
	}
}

- (void)fileWindowWillClose:(NSNotification *)notification
{
	NSWindow *window = [notification object];
	NSUInteger i;

	for (i = 0; i < [_fileWindows count]; i++) {
		WSFileWindowController *controller = [_fileWindows objectAtIndex:i];

		if ([controller window] == window) {
			[[NSNotificationCenter defaultCenter] removeObserver:self
				name:NSWindowWillCloseNotification object:window];
			/* DEFERRED: the close that posted this notification is still on the stack. */
			[controller retain];
			[_fileWindows removeObjectAtIndex:i];
			[controller autorelease];
			return;
		}
	}
}

/* THE APPLICATION'S OWN ROW. Everything else the menus offer is a window's or the responder chain's. */
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	(void)menuItem;
	return YES;
}

/* ---- THE APPLICATION MENU'S OWN TWO ROWS ----------------------------------------------------------- */

- (void)setShowsAboutOnStart:(BOOL)flag
{
	_showsAboutOnStart = flag;
}

- (void)orderFrontAboutPanel:(id)sender
{
	(void)sender;
	[WSAboutPanel orderFront];
}

/* **THE PREFERENCES WINDOW IS MADE ONCE AND KEPT.** A person opens Preferences, changes something, closes it and
 * opens it again, and a window remade each time would come back showing a value the slider had already moved away
 * from. So the FIRST call makes it — with the size the desktop is actually using — and every call after that just
 * brings it forward. */
- (void)showPreferences:(id)sender
{
	(void)sender;
	if (_preferences == nil) {
		_preferences = [[WSPreferencesWindow alloc] initWithTarget:self
								  iconSize:[_desktop iconSize]
								 directory:[WSApplication desktopDirectory]];
	}
	[_preferences orderFront];
}

- (void)preferencesWindow:(id)window didChangeIconSize:(NSInteger)size
{
	(void)window;
	[_desktop setIconSize:size];
}

- (void)dealloc
{
	[self stop];
	[_fileWindows release];
	[super dealloc];
}

@end
