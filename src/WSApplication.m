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

#include <stdio.h>

@implementation WSApplication

- (BOOL)start
{
	NSScreen *screen = [NSScreen mainScreen];

	_desktop = [[WSDesktopWindow alloc] initWithScreen:screen];
	if (_desktop == nil) {
		return NO;
	}
	[_desktop orderFront:nil];
	fprintf(stderr, "workspace: desktop window at level %ld, frame %gx%g at (%g,%g)\n",
		(long)[_desktop level], (double)[_desktop frame].size.width, (double)[_desktop frame].size.height,
		(double)[_desktop frame].origin.x, (double)[_desktop frame].origin.y);
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
