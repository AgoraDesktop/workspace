/*
 * WSApplication.m — create the desktop, put it on the screen, pump.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSApplication.h"

#import "WSAboutPanel.h"
#import "WSDesktopWindow.h"
#import "WSMainMenu.h"
#import "WSPreferencesWindow.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSScreen.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSString.h>

#include <stdio.h>
#include <stdlib.h>

@implementation WSApplication

/* WHICH DIRECTORY IS THE DESKTOP. `~/Desktop`, or `AGORA_DESKTOP` when it is set — the door the suite uses to
 * point a desktop at a directory it controls. A shell session names the real one; W1 does not yet have a
 * preferences system to name it any other way. */
+ (NSString *)desktopDirectory
{
	const char *override = getenv("AGORA_DESKTOP");
	const char *home = getenv("HOME");

	if (override != NULL && *override != '\0') return [NSString stringWithUTF8String:override];
	if (home == NULL || *home == '\0') return @"/tmp";
	return [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Desktop"];
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

	fprintf(stderr, "workspace: desktop window at level %ld, frame %gx%g at (%g,%g), showing %s\n",
		(long)[_desktop level], (double)[_desktop frame].size.width, (double)[_desktop frame].size.height,
		(double)[_desktop frame].origin.x, (double)[_desktop frame].origin.y, [directory UTF8String]);
	return YES;
}

- (void)runForSeconds:(double)seconds
{
	NSApplication *application = [NSApplication sharedApplication];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
	int events = 0;

	while ([deadline timeIntervalSinceNow] > 0.0) {
		NSEvent *event = [application nextEventMatchingMask:NSAnyEventMask
							  untilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]
							     inMode:nil
							    dequeue:YES];

		if (event != nil) {
			[application sendEvent:event];
			events++;
		}
	}
	fprintf(stderr, "workspace: %d event(s)\n", events);
}

- (void)stop
{
	[_preferences release];
	_preferences = nil;
	[_desktop close];
	[_desktop release];
	_desktop = nil;
}

/* ---- THE APPLICATION MENU'S OWN TWO ROWS ----------------------------------------------------------- */

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
	[super dealloc];
}

@end
