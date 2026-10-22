/*
 * WSConflictSheet.m — one question, four answers.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 */
#import "WSConflictSheet.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSTextField.h>
#import <Foundation/NSString.h>

@implementation WSConflictSheet

+ (WSFileConflictResolution)askWithDestination:(NSString *)destination parentWindow:(NSWindow *)parent
{
	WSConflictSheet *sheet = [[WSConflictSheet alloc] initWithDestination:destination];
	WSFileConflictResolution answer;
	NSInteger code;

	(void)parent;
	code = [sheet run];
	if (code == WSConflictReplace) answer = WSConflictReplace;
	else if (code == WSConflictSkip) answer = WSConflictSkip;
	else if (code == WSConflictKeepBoth) answer = WSConflictKeepBoth;
	else answer = WSConflictSkip;
	[sheet release];
	return answer;
}

- (instancetype)initWithDestination:(NSString *)destination
{
	NSView *content;
	NSTextField *label;

	self = [super initWithContentRect:NSMakeRect(0.0, 0.0, 460.0, 150.0)
				styleMask:NSBorderlessWindowMask
				  backing:NSBackingStoreBuffered defer:NO];
	if (self == nil) {
		return nil;
	}
	_destination = [destination copy];
	[self setLevel:NSModalPanelWindowLevel];
	[self setTitle:@"An item already exists"];
	content = [self contentView];
	label = [[NSTextField alloc] initWithFrame:NSMakeRect(18.0, 84.0, 424.0, 44.0)];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBordered:NO];
	[label setBezeled:NO];
	[label setDrawsBackground:NO];
	[label setStringValue:[NSString stringWithFormat:
		@"An item named “%@” already exists. Replace it, skip this item, keep both, or cancel?",
		[destination lastPathComponent]]];
	[content addSubview:label];
	[label release];
	{
		NSArray *titles = [NSArray arrayWithObjects:@"Replace", @"Skip", @"Keep Both", @"Cancel", nil];
		NSInteger tags[4] = { WSConflictReplace, WSConflictSkip, WSConflictKeepBoth, WSConflictSkip };
		CGFloat x = 18.0;
		NSUInteger i;

		for (i = 0; i < 4; i++) {
			NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(x, 24.0, 100.0, 28.0)];

			[button setTitle:[titles objectAtIndex:i]];
			[button setTag:tags[i]];
			[button setTarget:self];
			[button setAction:@selector(choose:)];
			[content addSubview:button];
			[button release];
			x += 108.0;
		}
	}
	return self;
}

- (void)dealloc
{
	[_destination release];
	[super dealloc];
}

- (WSFileConflictResolution)run
{
	NSInteger code = [NSApp runModalForWindow:self];

	[self orderOut:nil];
	if (code == WSConflictReplace) return WSConflictReplace;
	if (code == WSConflictKeepBoth) return WSConflictKeepBoth;
	return WSConflictSkip;
}

- (void)choose:(id)sender
{
	[NSApp stopModalWithCode:[(NSButton *)sender tag]];
}

@end
