/*
 * WSPreferencesWindow.m — one slider, one read-only fact, and the two doors between them and the desktop.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE SLIDER IS CONTINUOUS, SO THE DESKTOP MOVES WHILE THE KNOB DOES.** `NSControl`'s tracking loop is what
 * sends the action — this class needs no `-mouseDown:` of its own, which is the same reason `NSSlider`'s own header
 * says its tracking is not there — and `-setContinuous:YES` is what makes it send more than once. A preferences
 * window whose effect only appears when the mouse comes up would be a window a person cannot aim.
 *
 * **AND IT WRITES THROUGH THE SAME STORE THE DESKTOP READS.** The icon size is not a copy: the slider's value goes
 * to `WSApplication`, which hands it to the desktop view, which puts it in `WSMetadataStore` and SAVES — so the
 * preference survives the application, lands in the folder's `.agora` file, and is what the next launch lays out
 * with. A preferences window that set a variable only it knew about would be a settings panel that forgets.
 */
#import "WSPreferencesWindow.h"

#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSControl.h>
#import <AppKit/NSSlider.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/NSString.h>

/* **THE RANGE IS THE STORE'S, NOT THIS WINDOW'S.** `-[WSMetadataStore setIconSize:]` accepts 16..512 and ignores
 * anything else, so a slider that offered more would be offering sizes the answer would silently drop. The default
 * is 64 (the reference file manager's large-icon size); 16 is the small end the store allows and 128 the largest a desktop
 * wants. */
static const NSInteger WSPreferencesMinimumIconSize = 16;
static const NSInteger WSPreferencesMaximumIconSize = 128;

@implementation WSPreferencesWindow

- (instancetype)initWithTarget:(id <WSPreferencesWindowTarget>)target
		      iconSize:(NSInteger)iconSize
		     directory:(NSString *)directory
		      viewMode:(NSInteger)viewMode
{
	/* **TALLER BY THE ROW THE VIEW SWITCH NEEDS**, and nothing else moved: the icon-size slider keeps its y, the folder
	 * and the note keep theirs, and the new row sits above them. */
	NSRect frame = NSMakeRect(0.0, 0.0, 420.0, 250.0);
	NSView *content = [[[NSView alloc] initWithFrame:frame] autorelease];
	NSWindow *window;
	NSTextField *heading;
	NSTextField *folderHeading;
	NSTextField *folderValue;
	NSTextField *note;
	NSSlider *slider;
	NSTextField *valueLabel;

	self = [super init];
	if (self == nil) {
		return nil;
	}
	_target = target;			/* assign: the application owns this window, not the other way round */
	_iconSize = iconSize;
	_viewMode = (viewMode >= 0 && viewMode <= 2) ? viewMode : 0;

	window = [[NSWindow alloc] initWithContentRect:frame
					     styleMask:NSTitledWindowMask | NSClosableWindowMask
					       backing:NSBackingStoreBuffered
						 defer:NO];
	if (window == nil) {
		[self release];
		return nil;
	}
	[window setTitle:@"Workspace Preferences"];

	/* **EVERY LABEL IS AN UNEDITABLE, UNBEZELLED FIELD WITH NO BACKGROUND** — which is what a label is here: this
	 * tier has no `NSTextField +labelWithString:`, and a field that draws its own white surface would read as
	 * something a person could type into. */
	{
		NSTextField *viewHeading = [[NSTextField alloc] initWithFrame:NSMakeRect(20.0, 206.0, 200.0, 20.0)];
		NSSegmentedControl *modes;
		NSInteger segment;

		[viewHeading setStringValue:@"Default view for new windows:"];
		[viewHeading setEditable:NO];
		[viewHeading setSelectable:NO];
		[viewHeading setBezeled:NO];
		[viewHeading setBordered:NO];
		[viewHeading setDrawsBackground:NO];
		[viewHeading setFont:[NSFont systemFontOfSize:12.0]];
		[content addSubview:viewHeading];
		[viewHeading release];

		/* **THREE WORDS IN THE ORDER THE TOOLBAR SWITCHES THEM.** The toolbar's switch is three PICTURES because a band has
		 * no room for a word; a preferences row has the room, and a word is what a preference should say. */
		modes = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(20.0, 176.0, 240.0, 24.0)];
		[modes setSegmentCount:3];
		for (segment = 0; segment < 3; segment++) {
			NSArray *labels = [NSArray arrayWithObjects:@"Icon", @"List", @"Column", nil];

			[modes setLabel:[labels objectAtIndex:(NSUInteger)segment] forSegment:segment];
			[modes setWidth:0.0 forSegment:segment];
		}
		[modes setSelectedSegment:_viewMode];
		[modes setTarget:self];
		[modes setAction:@selector(viewModeChanged:)];
		[content addSubview:modes];
		_viewModeControl = [modes retain];
		[modes release];
	}

	heading = [[NSTextField alloc] initWithFrame:NSMakeRect(20.0, 140.0, 200.0, 20.0)];
	[heading setStringValue:@"Desktop icon size:"];
	[heading setEditable:NO];
	[heading setSelectable:NO];
	[heading setBezeled:NO];
	[heading setBordered:NO];
	[heading setDrawsBackground:NO];
	[heading setFont:[NSFont systemFontOfSize:12.0]];
	[content addSubview:heading];
	[heading release];

	slider = [[NSSlider alloc] initWithFrame:NSMakeRect(20.0, 112.0, 280.0, 24.0)];
	[slider setMinValue:(double)WSPreferencesMinimumIconSize];
	[slider setMaxValue:(double)WSPreferencesMaximumIconSize];
	[slider setIntValue:(int)iconSize];
	[slider setContinuous:YES];
	[slider setTarget:self];
	[slider setAction:@selector(iconSizeChanged:)];
	[content addSubview:slider];
	[slider release];

	valueLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(310.0, 112.0, 96.0, 20.0)];
	[valueLabel setEditable:NO];
	[valueLabel setSelectable:NO];
	[valueLabel setBezeled:NO];
	[valueLabel setBordered:NO];
	[valueLabel setDrawsBackground:NO];
	[valueLabel setFont:[NSFont systemFontOfSize:12.0]];
	[content addSubview:valueLabel];

	folderHeading = [[NSTextField alloc] initWithFrame:NSMakeRect(20.0, 52.0, 200.0, 20.0)];
	[folderHeading setStringValue:@"Desktop folder:"];
	[folderHeading setEditable:NO];
	[folderHeading setSelectable:NO];
	[folderHeading setBezeled:NO];
	[folderHeading setBordered:NO];
	[folderHeading setDrawsBackground:NO];
	[folderHeading setFont:[NSFont systemFontOfSize:12.0]];
	[content addSubview:folderHeading];
	[folderHeading release];

	folderValue = [[NSTextField alloc] initWithFrame:NSMakeRect(20.0, 28.0, 380.0, 18.0)];
	[folderValue setStringValue:(directory != nil) ? directory : @""];
	[folderValue setEditable:NO];
	[folderValue setSelectable:YES];	/* a path is the one thing here worth copying */
	[folderValue setBezeled:NO];
	[folderValue setBordered:NO];
	[folderValue setDrawsBackground:NO];
	[folderValue setFont:[NSFont systemFontOfSize:11.0]];
	[folderValue setTextColor:[NSColor darkGrayColor]];
	[content addSubview:folderValue];
	[folderValue release];

	/* WHAT THE SLIDER JUST WROTE, said in the window rather than left to be discovered in a sidecar. */
	note = [[NSTextField alloc] initWithFrame:NSMakeRect(20.0, 8.0, 380.0, 16.0)];
	[note setStringValue:@"Icon size is saved in the desktop folder's .agora file."];
	[note setEditable:NO];
	[note setSelectable:NO];
	[note setBezeled:NO];
	[note setBordered:NO];
	[note setDrawsBackground:NO];
	[note setFont:[NSFont systemFontOfSize:10.0]];
	[note setTextColor:[NSColor darkGrayColor]];
	[content addSubview:note];
	[note release];

	[window setContentView:content];
	_window = window;
	_slider = [slider retain];
	_valueLabel = [valueLabel retain];
	[self iconSizeChanged:nil];		/* so the value label says something before anyone drags */

	return self;
}

- (void)dealloc
{
	[_slider release];
	[_valueLabel release];
	[_viewModeControl release];
	[_window release];
	[super dealloc];
}

/* The slider's own door, and the only place the value is read: the label is updated from it and the application is
 * told, so what is SHOWN and what is APPLIED cannot drift apart. */
/* **THE VIEW SWITCH'S OWN DOOR**: the segment a person chose is the mode the target is told about, and it is kept here so
 * `-viewMode` answers what the window shows rather than asking the control a second time. */
- (void)viewModeChanged:(id)sender
{
	NSInteger segment = 0;

	(void)sender;
	if (_viewModeControl != nil) {
		segment = (NSInteger)[_viewModeControl selectedSegment];
	}
	if (segment < 0 || segment > 2) {
		return;
	}
	_viewMode = segment;
	if (_target != nil && [_target respondsToSelector:@selector(preferencesWindow:didChangeViewMode:)]) {
		[_target preferencesWindow:self didChangeViewMode:segment];
	}
}

- (NSInteger)viewMode
{
	return _viewMode;
}

- (NSSegmentedControl *)cg_viewModeControl
{
	return _viewModeControl;
}

- (void)iconSizeChanged:(id)sender
{
	NSInteger size = (_slider != nil) ? (NSInteger)[_slider intValue] : _iconSize;

	(void)sender;
	_iconSize = size;
	if (_valueLabel != nil) {
		[_valueLabel setStringValue:[NSString stringWithFormat:@"%ld points", (long)size]];
	}
	if (_target != nil && [_target respondsToSelector:@selector(preferencesWindow:didChangeIconSize:)]) {
		[_target preferencesWindow:self didChangeIconSize:size];
	}
}

- (NSInteger)iconSize
{
	return _iconSize;
}

- (void)orderFront
{
	[_window center];
	[_window makeKeyAndOrderFront:nil];
}

@end
