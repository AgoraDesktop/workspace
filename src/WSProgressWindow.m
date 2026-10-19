/*
 * WSProgressWindow.m — a message and a bar.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 */
#import "WSProgressWindow.h"

#import <AppKit/NSColor.h>
#import <AppKit/NSProgressIndicator.h>
#import <AppKit/NSTextField.h>
#import <Foundation/NSString.h>

@implementation WSProgressWindow

- (instancetype)init
{
	NSView *content;

	self = [super initWithContentRect:NSMakeRect(0.0, 0.0, 360.0, 82.0)
				styleMask:NSBorderlessWindowMask
				  backing:NSBackingStoreBuffered defer:NO];
	if (self == nil) {
		return nil;
	}
	[self setLevel:NSFloatingWindowLevel];
	[self setOpaque:YES];
	[self setHasShadow:YES];
	[self setTitle:@"Progress"];
	content = [self contentView];
	_message = [[NSTextField alloc] initWithFrame:NSMakeRect(16.0, 48.0, 328.0, 20.0)];
	[_message setEditable:NO];
	[_message setSelectable:NO];
	[_message setBordered:NO];
	[_message setBezeled:NO];
	[_message setDrawsBackground:NO];
	[_message setStringValue:@"Working…"];
	[content addSubview:_message];
	_bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(16.0, 20.0, 328.0, 16.0)];
	[_bar setMinValue:0.0];
	[_bar setMaxValue:1.0];
	[_bar setDoubleValue:0.0];
	[content addSubview:_bar];
	return self;
}

- (void)dealloc
{
	[_message release];
	[_bar release];
	[super dealloc];
}

- (void)setMessage:(NSString *)message
{
	[_message setStringValue:(message != nil) ? message : @"Working…"];
}

- (void)setCompleted:(NSUInteger)completed total:(NSUInteger)total path:(NSString *)path
{
	[_bar setMaxValue:(total > 0) ? (double)total : 1.0];
	[_bar setDoubleValue:(double)completed];
	if (path != nil) {
		[_message setStringValue:[NSString stringWithFormat:@"%lu of %lu — %@",
					  (unsigned long)completed, (unsigned long)total, path]];
	}
}

- (void)show
{
	[self center];
	[self orderFront:nil];
}

- (void)hide
{
	[self orderOut:nil];
}

@end
