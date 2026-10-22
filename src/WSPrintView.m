/*
 * WSPrintView.m — the listing, its rows and its ink.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Portions of this file may derive from GNUstep; see THIRD-PARTY.md.
 *
 * **THE ROWS ARE BUILT ONCE, FROM THE FILE SYSTEM, AND THEN DRAWN.** A row holds the four strings the page shows —
 * name, kind, size, date — so drawing needs no file manager and no stat: the print operation may ask for the view
 * twice (once to paginate, once to draw) and both answers are the same.
 *
 * The kind is `WSItemKind`'s, through a `WSItem` made for the path, so a printed listing names a file the same way the
 * list view does — one registry, not a second extension table in a print path.
 */
#import "WSPrintView.h"

#import "WSItemKind.h"
#import "WSItemModel.h"

#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSStringDrawing.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>

#include <math.h>

/* ONE ROW'S FOUR STRINGS. */
@interface WSPrintRow : NSObject
{
@public
	NSString *name;
	NSString *kind;
	NSString *size;
	NSString *date;
}
@end

@implementation WSPrintRow
- (void)dealloc
{
	[name release];
	[kind release];
	[size release];
	[date release];
	[super dealloc];
}
@end

static NSString *WSSizeString(unsigned long long bytes, BOOL isDirectory)
{
	if (isDirectory) {
		return @"--";
	}
	if (bytes < 1024ULL) {
		return [NSString stringWithFormat:@"%llu bytes", bytes];
	}
	if (bytes < 1024ULL * 1024ULL) {
		return [NSString stringWithFormat:@"%.1f KB", (double)bytes / 1024.0];
	}
	return [NSString stringWithFormat:@"%.1f MB", (double)bytes / (1024.0 * 1024.0)];
}

@implementation WSPrintView

+ (WSPrintView *)printViewForPaths:(NSArray *)paths title:(NSString *)title
{
	WSPrintView *view;
	NSMutableArray *rows;
	NSFileManager *manager = [NSFileManager defaultManager];
	NSUInteger i;
	NSString *resolvedTitle = title;

	if (resolvedTitle == nil && [paths count] > 0) {
		resolvedTitle = [[paths objectAtIndex:0] lastPathComponent];
	}
	rows = [NSMutableArray array];
	for (i = 0; i < [paths count]; i++) {
		NSString *path = [paths objectAtIndex:i];
		NSDictionary *attributes = [manager attributesOfItemAtPath:path error:NULL];
		BOOL isDirectory = [[attributes objectForKey:NSFileType] isEqual:NSFileTypeDirectory];
		WSItem *item = [[[WSItem alloc] initWithName:[path lastPathComponent] path:path
						isDirectory:isDirectory] autorelease];
		WSPrintRow *row = [[[WSPrintRow alloc] init] autorelease];
		NSDate *modified = [attributes objectForKey:NSFileModificationDate];

		row->name = [[path lastPathComponent] copy];
		row->kind = [[WSItemKind kindForItem:item] copy];
		row->size = [WSSizeString([[attributes objectForKey:NSFileSize] unsignedLongLongValue],
					  isDirectory) copy];
		row->date = [(modified != nil ? [modified description] : @"") copy];
		[rows addObject:row];
	}
	view = [[[self alloc] initWithFrame:NSMakeRect(0.0, 0.0, WS_PRINT_VIEW_WIDTH, 0.0)] autorelease];
	view->_title = [(resolvedTitle != nil ? resolvedTitle : @"") copy];
	view->_rows = [rows copy];
	[view setFrameSize:NSMakeSize(WS_PRINT_VIEW_WIDTH, [view cg_requiredHeight])];
	return view;
}

- (void)dealloc
{
	[_title release];
	[_rows release];
	[super dealloc];
}

- (BOOL)isFlipped
{
	return YES;
}

- (CGFloat)cg_requiredHeight
{
	return WS_PRINT_TITLE_HEIGHT + (CGFloat)[_rows count] * WS_PRINT_ROW_HEIGHT + WS_PRINT_BOTTOM_PADDING;
}

- (NSString *)cg_title
{
	return _title;
}

- (NSArray *)cg_rows
{
	return _rows;
}

- (NSString *)cg_nameAtRow:(NSUInteger)index
{
	return (index < [_rows count]) ? ((WSPrintRow *)[_rows objectAtIndex:index])->name : nil;
}

- (NSString *)cg_kindAtRow:(NSUInteger)index
{
	return (index < [_rows count]) ? ((WSPrintRow *)[_rows objectAtIndex:index])->kind : nil;
}

- (NSString *)cg_sizeAtRow:(NSUInteger)index
{
	return (index < [_rows count]) ? ((WSPrintRow *)[_rows objectAtIndex:index])->size : nil;
}

- (NSString *)cg_dateAtRow:(NSUInteger)index
{
	return (index < [_rows count]) ? ((WSPrintRow *)[_rows objectAtIndex:index])->date : nil;
}

/* **THE TITLE BAND, A RULE, AND THEN THE ROWS.** Two fonts and two inks: the title in the control's text colour, the
 * rows in it too, and the rule in the border grey. Everything is drawn at a baseline through `-drawAtPoint:`, which is
 * the one text path this tier has, so a printed row sits where the list view puts it. */
- (void)drawRect:(NSRect)dirtyRect
{
	NSDictionary *titleAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont boldSystemFontOfSize:15.0], NSFontAttributeName,
		[NSColor blackColor], NSForegroundColorAttributeName, nil];
	NSDictionary *rowAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont systemFontOfSize:9.0], NSFontAttributeName,
		[NSColor blackColor], NSForegroundColorAttributeName, nil];
	NSDictionary *headAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
		[NSFont boldSystemFontOfSize:8.0], NSFontAttributeName,
		[NSColor darkGrayColor], NSForegroundColorAttributeName, nil];
	CGFloat width = NSWidth([self bounds]);
	NSUInteger i;

	(void)dirtyRect;
	/* A WHITE SHEET UNDER EVERYTHING: a print page has no window background behind it. */
	[[NSColor whiteColor] setFill];
	[[NSBezierPath bezierPathWithRect:[self bounds]] fill];

	[_title drawAtPoint:NSMakePoint(0.0, 12.0) withAttributes:titleAttributes];
	[@"Name" drawAtPoint:NSMakePoint(0.0, 36.0) withAttributes:headAttributes];
	[@"Kind" drawAtPoint:NSMakePoint(width - 200.0, 36.0) withAttributes:headAttributes];
	[@"Size" drawAtPoint:NSMakePoint(width - 96.0, 36.0) withAttributes:headAttributes];
	[@"Modified" drawAtPoint:NSMakePoint(width - 72.0, 36.0) withAttributes:headAttributes];

	[[NSColor lightGrayColor] setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, WS_PRINT_TITLE_HEIGHT - 2.0, width, 1.0)] fill];

	for (i = 0; i < [_rows count]; i++) {
		WSPrintRow *row = [_rows objectAtIndex:i];
		CGFloat baseline = WS_PRINT_TITLE_HEIGHT + 4.0 + (CGFloat)i * WS_PRINT_ROW_HEIGHT;
		NSString *name = row->name;
		NSString *kind = row->kind;

		/* A NAME LONGER THAN ITS COLUMN IS CUT RATHER THAN ALLOWED TO RUN INTO THE KIND: the listing's columns are
		 * what make it readable, and an ellipsis is one character of arithmetic. */
		if ([name length] > 42) {
			name = [[name substringToIndex:39] stringByAppendingString:@"..."];
		}
		if ([kind length] > 24) {
			kind = [[kind substringToIndex:21] stringByAppendingString:@"..."];
		}
		[name drawAtPoint:NSMakePoint(0.0, baseline) withAttributes:rowAttributes];
		[kind drawAtPoint:NSMakePoint(width - 200.0, baseline) withAttributes:rowAttributes];
		[row->size drawAtPoint:NSMakePoint(width - 96.0, baseline) withAttributes:rowAttributes];
		[row->date drawAtPoint:NSMakePoint(width - 72.0, baseline) withAttributes:rowAttributes];
	}
}

@end
