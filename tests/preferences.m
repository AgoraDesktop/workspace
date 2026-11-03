/*
 * preferences — the row that decides which view a NEW file window opens in.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A PERSON BROWSES THEIR FOLDERS ONE OF THREE WAYS ALMOST ALWAYS, AND CHOOSING IT AGAIN IN EVERY NEW WINDOW IS THE TAX
 * THIS PREFERENCE REMOVES.** The window has one row for it — Icon, List, Column — and the answer is written where a file
 * window reads it, so both halves are measured here: the control and the callback, and the door the window asks at the
 * moment it is made.
 *
 * THE DEFAULTS ARE THE PROBE'S OWN. `AGORA_CONFIG_ROOT` is set before anything asks, so the value written here is a file
 * in a temporary directory rather than in the person's account.
 */
#import "WSFileWindowController.h"
#import "WSPreferencesWindow.h"

#import <AppKit/NSSegmentedControl.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int s_failed;

static void check(int condition, const char *message)
{
	printf("%s %s\n", condition ? "  ok  " : "  FAIL", message);
	if (!condition) {
		s_failed++;
	}
}

/* THE TARGET A WINDOW TALKS TO: what a choice was reported as, and how many times. */
@interface AGPreferencesProbe : NSObject <WSPreferencesWindowTarget>
{
@public
	NSInteger iconSizeChanges;
	NSInteger lastIconSize;
	NSInteger viewModeChanges;
	NSInteger lastViewMode;
}
@end

@implementation AGPreferencesProbe

- (void)preferencesWindow:(WSPreferencesWindow *)window didChangeIconSize:(NSInteger)size
{
	(void)window;
	iconSizeChanges++;
	lastIconSize = size;
}

- (void)preferencesWindow:(WSPreferencesWindow *)window didChangeViewMode:(NSInteger)mode
{
	(void)window;
	viewModeChanges++;
	lastViewMode = mode;
}

@end

int main(void)
{
	@autoreleasepool {
		NSString *root = [@"/tmp" stringByAppendingPathComponent:
			[NSString stringWithFormat:@"agora-preferences-%d", (int)getpid()]];
		NSString *config = [root stringByAppendingPathComponent:@"config"];
		AGPreferencesProbe *probe;
		WSPreferencesWindow *window;
		NSSegmentedControl *control;

		setvbuf(stdout, NULL, _IONBF, 0);
		[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
		[[NSFileManager defaultManager] createDirectoryAtPath:config withIntermediateDirectories:YES
							   attributes:nil error:NULL];
		setenv("AGORA_CONFIG_ROOT", [config UTF8String], 1);

		/* 1. THE DEFAULT IS THE WINDOW'S, AND A PREFERENCE NOBODY SET IS ICON. */
		check([WSFileWindowController cg_defaultViewMode] == 0,
		      "a preference nobody has set is Icon, which is what Windows a file manager opens on");
		[WSFileWindowController cg_setDefaultViewMode:2];
		check([WSFileWindowController cg_defaultViewMode] == 2, "and setting it is what the next window reads");
		[WSFileWindowController cg_setDefaultViewMode:7];
		check([WSFileWindowController cg_defaultViewMode] == 2, "a mode that is not one of the three is refused");
		[WSFileWindowController cg_setDefaultViewMode:1];

		/* 2. THE WINDOW SHOWS IT, AND CHOOSING ANOTHER TELLS THE TARGET. */
		probe = [[AGPreferencesProbe alloc] init];
		window = [[WSPreferencesWindow alloc] initWithTarget:probe iconSize:64
							   directory:@"/tmp" viewMode:1];
		check(window != nil, "the preferences window is made");
		check([[window cg_viewModeControl] segmentCount] == 3, "with three views to choose between");
		control = [window cg_viewModeControl];
		if (control != nil) {
			NSInteger i;
			NSArray *labels = [NSArray arrayWithObjects:@"Icon", @"List", @"Column", nil];
			BOOL named = YES;

			for (i = 0; i < 3; i++) {
				NSString *label = [control labelForSegment:i];

				printf("  (note: segment %ld is %s\n", (long)i,
				       label != nil ? [label UTF8String] : "(none)");
				if (label == nil || ![label isEqual:[labels objectAtIndex:(NSUInteger)i]]) {
					named = NO;
				}
			}
			check(named, "and each segment says which view it is, in the toolbar's own order");
			check([control selectedSegment] == 1, "the switch starts on the mode the window was made with");

			[control setSelectedSegment:0];
			[control sendAction:[control action] to:[control target]];
			check(probe->viewModeChanges == 1 && probe->lastViewMode == 0,
			      "choosing Icon tells the target it is Icon, once");
			check([window viewMode] == 0, "and the window now says Icon is what it shows");

			[control setSelectedSegment:2];
			[control sendAction:[control action] to:[control target]];
			check(probe->viewModeChanges == 2 && probe->lastViewMode == 2,
			      "and choosing Column tells it Column");
			[WSFileWindowController cg_setDefaultViewMode:0];	/* the probe's own defaults: back to Icon */
		}

		/* 3. THE SLIDER'S HALF IS UNTOUCHED: the row that was already here is not a casualty of the new one. */
		check([window iconSize] == 64, "the icon-size row still answers the size it was made with");
		[probe release];
		[window release];

		[[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
	}
	printf(s_failed == 0 ? "preferences: all checks passed\n" : "preferences: FAILURES\n");
	return s_failed == 0 ? 0 : 1;
}
