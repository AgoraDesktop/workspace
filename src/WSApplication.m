/*
 * WSApplication.m — create the desktop, put it on the screen, pump.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSApplication.h"

#import "WSDesktopWindow.h"

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
	NSScreen *screen = [NSScreen mainScreen];
	NSString *directory = [WSApplication desktopDirectory];

	_desktop = [[WSDesktopWindow alloc] initWithScreen:screen directory:directory];
	if (_desktop == nil) {
		return NO;
	}
	[_desktop orderFront:nil];
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
	[_desktop close];
	[_desktop release];
	_desktop = nil;
}

- (void)dealloc
{
	[self stop];
	[super dealloc];
}

@end
