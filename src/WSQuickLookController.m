/*
 * WSQuickLookController.m — the panel, its view, and the four things it can draw.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#import "WSQuickLookController.h"

#import "WSItemIcons.h"

#import <AppKit/AGImageSourceRep.h>

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSPDFImageRep.h>
#import <AppKit/NSScreen.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSWindow.h>

#import <Foundation/NSData.h>
#import <Foundation/NSDate.h>

#include <stdlib.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>

/* **THE PANEL IS A FRACTION OF THE SCREEN, NOT A SIZE IN POINTS.** A glance should leave the window it came from visible
 * around it, and what that means depends on the display: 64% of the visible frame, with a floor for a small output and a
 * ceiling so a 4K panel does not cover the whole desk with one photograph. */
static const CGFloat WSQuickLookScreenShare = 0.64;
static const CGFloat WSQuickLookMinimumWidth = 320.0;
static const CGFloat WSQuickLookMinimumHeight = 240.0;
static const CGFloat WSQuickLookMaximumWidth = 1100.0;
static const CGFloat WSQuickLookMaximumHeight = 800.0;

/* HOW MUCH OF A TEXT FILE A GLANCE SHOWS. Eight kilobytes is a couple of screens of prose at this panel's size, and it is
 * the same cap the inspector's preview uses for the same reason: a glance that reads a 200 MB log is not a glance. */
static const NSUInteger WSQuickLookTextLimit = 8192;

/* The panel's own face: a dark plate so a white page or a photograph has an edge, a lighter strip for the title, and the
 * ink the two of them draw. */
static const CGFloat WSQuickLookPlate = 0.16;
static const CGFloat WSQuickLookStrip = 0.26;
static const CGFloat WSQuickLookInk = 0.92;

/* ============================================================================================ *
 * THE VIEW                                                                                      *
 * ============================================================================================ */

@interface WSQuickLookView : NSView
{
	NSString *_title;	/* RETAINED: the file's name */
	NSString *_kind;	/* RETAINED: what the panel calls it */
	NSString *_text;	/* RETAINED: the preview text, or nil */
	NSImage *_picture;	/* RETAINED: an image file, at a size the panel asked for */
	NSPDFImageRep *_pdf;	/* RETAINED: a document, drawn as one vector page */
	NSImage *_icon;		/* RETAINED: a folder's or a plain file's own icon */
}
- (void)setTitle:(nullable NSString *)title kind:(nullable NSString *)kind text:(nullable NSString *)text
	 picture:(nullable NSImage *)picture pdf:(nullable NSPDFImageRep *)pdf icon:(nullable NSImage *)icon;
@end

@implementation WSQuickLookView

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_title release];
	[_kind release];
	[_text release];
	[_picture release];
	[_pdf release];
	[_icon release];
	[super dealloc];
}

- (void)setTitle:(NSString *)title kind:(NSString *)kind text:(NSString *)text picture:(NSImage *)picture
	 pdf:(NSPDFImageRep *)pdf icon:(NSImage *)icon
{
	NSString *oldTitle = _title;
	NSString *oldKind = _kind;
	NSString *oldText = _text;
	NSImage *oldPicture = _picture;
	NSPDFImageRep *oldPDF = _pdf;
	NSImage *oldIcon = _icon;

	_title = [title copy];
	_kind = [kind copy];
	_text = [text copy];
	_picture = [picture retain];
	_pdf = [pdf retain];
	_icon = [icon retain];
	[oldTitle release];
	[oldKind release];
	[oldText release];
	[oldPicture release];
	[oldPDF release];
	[oldIcon release];
	[self setNeedsDisplay:YES];
}

/* **A GLANCE IS DISMISSED BY A CLICK ON IT**, which is what Finder's panel does and what a person tries first. The click
 * is not forwarded: the panel is not a window to work in. */
- (void)mouseDown:(NSEvent *)event
{
	(void)event;
	[[NSNotificationCenter defaultCenter] postNotificationName:@"WSQuickLookDismissRequested" object:self];
}

/* THE PLATE, THE TITLE STRIP AND THE HINT, drawn once so the four kinds do not each repeat them. */
- (void)drawPlateWithTitleRect:(NSRect)titleRect contentRect:(NSRect)contentRect
{
	NSRect bounds = [self bounds];

	[[NSColor colorWithCalibratedWhite:WSQuickLookPlate alpha:1.0] setFill];
	[[NSBezierPath bezierPathWithRoundedRect:bounds xRadius:10.0 yRadius:10.0] fill];
	[[NSColor colorWithCalibratedWhite:WSQuickLookStrip alpha:1.0] setFill];
	[[NSBezierPath bezierPathWithRect:titleRect] fill];

	if (_title != nil) {
		NSMutableDictionary *attributes = [NSMutableDictionary dictionary];

		[attributes setObject:[NSFont boldSystemFontOfSize:13.0] forKey:NSFontAttributeName];
		[attributes setObject:[NSColor colorWithCalibratedWhite:WSQuickLookInk alpha:1.0]
			       forKey:NSForegroundColorAttributeName];
		[_title drawInRect:NSMakeRect(NSMinX(titleRect) + 12.0, NSMinY(titleRect) + 5.0,
					      NSWidth(titleRect) - 24.0, NSHeight(titleRect) - 8.0)
		    withAttributes:attributes];
	}
	if (_kind != nil) {
		NSMutableDictionary *attributes = [NSMutableDictionary dictionary];

		[attributes setObject:[NSFont systemFontOfSize:11.0] forKey:NSFontAttributeName];
		[attributes setObject:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]
			       forKey:NSForegroundColorAttributeName];
		[_kind drawInRect:NSMakeRect(NSMinX(contentRect), NSMinY(contentRect) + 4.0,
					     NSWidth(contentRect), 16.0)
		    withAttributes:attributes];
	}
	{
		NSMutableDictionary *attributes = [NSMutableDictionary dictionary];

		[attributes setObject:[NSFont systemFontOfSize:10.0] forKey:NSFontAttributeName];
		[attributes setObject:[NSColor colorWithCalibratedWhite:0.55 alpha:1.0]
			       forKey:NSForegroundColorAttributeName];
		[@"Space or Esc closes" drawInRect:NSMakeRect(NSWidth(bounds) - 140.0, 5.0, 130.0, 14.0)
			    withAttributes:attributes];
	}
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSRect bounds = [self bounds];
	NSRect titleRect = NSMakeRect(0.0, NSHeight(bounds) - 28.0, NSWidth(bounds), 28.0);
	NSRect content = NSMakeRect(10.0, 22.0, NSWidth(bounds) - 20.0, NSHeight(bounds) - 28.0 - 30.0);

	(void)dirtyRect;
	[self drawPlateWithTitleRect:titleRect contentRect:content];
	if (_picture != nil) {
		/* THE PICTURE'S OWN SHAPE, FITTED AND CENTRED — the same rule the inspector's pane follows, so a wide screenshot
		 * is not two bands of plate above and below a square. */
		NSSize size = [_picture size];
		CGFloat scale = NSWidth(content) / size.width;

		if (NSHeight(content) / size.height < scale) {
			scale = NSHeight(content) / size.height;
		}
		{
			NSSize drawn = NSMakeSize(size.width * scale, size.height * scale);
			NSRect frame = NSMakeRect(NSMidX(content) - drawn.width / 2.0, NSMidY(content) - drawn.height / 2.0,
						  drawn.width, drawn.height);

			[_picture drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
			       respectFlipped:NO hints:nil];
		}
		return;
	}
	if (_pdf != nil) {
		NSRect page = [_pdf bounds];
		CGFloat scale = NSWidth(content) / page.size.width;

		if (NSHeight(content) / page.size.height < scale) {
			scale = NSHeight(content) / page.size.height;
		}
		{
			NSSize drawn = NSMakeSize(page.size.width * scale, page.size.height * scale);
			NSRect frame = NSMakeRect(NSMidX(content) - drawn.width / 2.0, NSMidY(content) - drawn.height / 2.0,
						  drawn.width, drawn.height);

			/* THE PAGE'S PAPER FIRST, because a PDF's page is transparent where the document draws nothing and the plate
			 * would show through the margin of every page. */
			[[NSColor whiteColor] setFill];
			[[NSBezierPath bezierPathWithRect:frame] fill];
			[_pdf drawInRect:frame];
		}
		return;
	}
	if (_text != nil) {
		NSMutableDictionary *attributes = [NSMutableDictionary dictionary];

		[attributes setObject:[NSFont userFixedPitchFontOfSize:11.0] forKey:NSFontAttributeName];
		[attributes setObject:[NSColor colorWithCalibratedWhite:WSQuickLookInk alpha:1.0]
			       forKey:NSForegroundColorAttributeName];
		[_text drawInRect:content withAttributes:attributes];
		return;
	}
	if (_icon != nil) {
		NSSize size = [_icon size];
		CGFloat scale = 1.0;

		if (size.width > 128.0) {
			scale = 128.0 / size.width;
		}
		{
			NSRect frame = NSMakeRect(NSMidX(content) - size.width * scale / 2.0,
						  NSMidY(content) - size.height * scale / 2.0,
						  size.width * scale, size.height * scale);

			[_icon drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
			   respectFlipped:NO hints:nil];
		}
	}
}

@end

/* ============================================================================================ *
 * THE CONTROLLER                                                                                *
 * ============================================================================================ */

static WSQuickLookController *s_shared;

@implementation WSQuickLookController

+ (instancetype)sharedController
{
	if (s_shared == nil) {
		s_shared = [[self alloc] init];
	}
	return s_shared;
}

/* ============================================================================================ *
 * THE DECISIONS, WHICH ARE THE HALF THAT CAN BE ASKED WITHOUT A DISPLAY                             *
 * ============================================================================================ */

/* THE FIVE KINDS, ASKED IN THE ORDER THAT COSTS THE LEAST BEING WRONG ABOUT: the file system first (a directory is a
 * directory), then the image registry — which is a signature check and nothing else — then the PDF signature, and only then
 * the text sniff, which has to read bytes. */
+ (WSQuickLookKind)kindForPath:(NSString *)path
{
	NSFileManager *manager = [NSFileManager defaultManager];
	BOOL directory = NO;
	NSData *head;

	if (path == nil) {
		return WSQuickLookKindOther;
	}
	if (![manager fileExistsAtPath:path isDirectory:&directory]) {
		return WSQuickLookKindOther;
	}
	if (directory) {
		return WSQuickLookKindFolder;
	}
	head = [NSData dataWithContentsOfFile:path options:0 error:NULL];
	if (head == nil) {
		return WSQuickLookKindOther;
	}
	/* THE REGISTRY IS ASKED, so every format the drawing library decodes is a picture here without a second list of
	 * extensions going stale; a file it declines is not an image. */
	if ([AGImageSourceRep canInitWithData:head]) {
		return WSQuickLookKindImage;
	}
	if ([head length] >= 5 && memcmp([head bytes], "%PDF-", 5) == 0) {
		return WSQuickLookKindPDF;
	}
	if ([self textPreviewForPath:path limit:WSQuickLookTextLimit] != nil) {
		return WSQuickLookKindText;
	}
	return WSQuickLookKindOther;
}

/* **TEXT IS A GUESS THAT HAS TO BE MADE CAREFULLY.** A file is text when it holds no NUL byte and no more than a twentieth
 * of unprintable ones: that is what tells a source file from an ELF binary, and it is the rule every pager uses. The answer
 * is cut at the last newline so a glance does not end in half a line. */
+ (NSString *)textPreviewForPath:(NSString *)path limit:(NSUInteger)limit
{
	NSData *data;
	const unsigned char *bytes;
	NSUInteger length;
	NSUInteger i;
	NSUInteger bad = 0;
	NSString *text;

	if (path == nil || limit == 0) {
		return nil;
	}
	data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
	if (data == nil || [data length] == 0) {
		return nil;
	}
	bytes = [data bytes];
	length = [data length];
	if (length > limit) {
		length = limit;
	}
	for (i = 0; i < length; i++) {
		unsigned char c = bytes[i];

		if (c == 0) {
			return nil;	/* a NUL byte is a binary file's signature in every text format */
		}
		if (c < 0x09 || (c > 0x0d && c < 0x20)) {
			bad++;
		}
	}
	if (bad * 20 > length) {
		return nil;
	}
	text = [[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding] autorelease];
	if (text == nil) {
		return nil;	/* bytes that are not UTF-8 are not this reader's text */
	}
	{
		NSRange newline = [text rangeOfString:@"\n" options:NSBackwardsSearch];

		if (newline.location != NSNotFound && newline.location > 0) {
			text = [text substringToIndex:newline.location];
		}
	}
	return ([text length] > 0) ? text : nil;
}

- (NSString *)kindName
{
	WSQuickLookKind kind;

	if (_path == nil) {
		return nil;
	}
	kind = [WSQuickLookController kindForPath:_path];
	switch (kind) {
	case WSQuickLookKindImage: return @"Image";
	case WSQuickLookKindPDF: return @"PDF document";
	case WSQuickLookKindText: return @"Text";
	case WSQuickLookKindFolder: return @"Folder";
	default: break;
	}
	return @"Document";
}

/* ============================================================================================ *
 * THE PANEL                                                                                      *
 * ============================================================================================ */

/* **THE PANEL IS BUILT WHEN IT IS FIRST ASKED FOR, WHICH IS `-loadWindow`.** An `NSWindowController` with no window sends
 * `-loadWindow` on the first `-window`, and that is the door this tier's own exception message names — so the panel is made
 * there rather than in `-init`. MEASURED, the other way round: `+sharedController` runs before the application has started,
 * so a window built in `-init` had no server to be made on — it came out at the minimum size, `-orderFront:` could not map
 * it, and a glance showed nothing at all.
 *
 * It is made once and reused: a second glance replaces the first rather than stacking borderless panels. */
- (NSWindow *)cg_makePanel
{
	NSScreen *screen = [NSScreen mainScreen];
	NSSize visible = (screen != nil) ? [screen visibleFrame].size : NSMakeSize(1024.0, 768.0);
	CGFloat width = visible.width * WSQuickLookScreenShare;
	CGFloat height = visible.height * WSQuickLookScreenShare;
	NSWindow *panel;
	WSQuickLookView *view;

	if (width < WSQuickLookMinimumWidth) {
		width = WSQuickLookMinimumWidth;
	}
	if (width > WSQuickLookMaximumWidth) {
		width = WSQuickLookMaximumWidth;
	}
	if (height < WSQuickLookMinimumHeight) {
		height = WSQuickLookMinimumHeight;
	}
	if (height > WSQuickLookMaximumHeight) {
		height = WSQuickLookMaximumHeight;
	}
	panel = [[NSWindow alloc] initWithContentRect:NSMakeRect(0.0, 0.0, width, height)
					    styleMask:NSBorderlessWindowMask
					      backing:NSBackingStoreBuffered
						defer:NO];
	[panel setReleasedWhenClosed:NO];
	[panel setOpaque:YES];
	view = [[WSQuickLookView alloc] initWithFrame:NSMakeRect(0.0, 0.0, width, height)];
	[panel setContentView:view];
	_panelView = view;
	/* **A GLANCE DOES NOT TAKE THE KEYBOARD.** The space that opened it and the space that closes it belong to the file
	 * window's view, so the panel must not become the key window — the same rule the Dock's tiles follow. And the call is
	 * what MAKES the platform window, which is why the LEVEL IS SET AFTER IT: `-setLevel:` records the number and applies
	 * it only to a window that exists, so a level set first was stored and never sent — MEASURED as a panel that was
	 * visible, 778x445, at level 3 in its own records and BEHIND an ordinary file window on the glass, because the
	 * compositor had been told level 0. */
	[panel cg_setActivatable:NO];
	[panel setLevel:(getenv("WS_QUICKLOOK_LEVEL") != NULL) ? atoi(getenv("WS_QUICKLOOK_LEVEL")) : NSFloatingWindowLevel];
	return panel;
}

- (void)loadWindow
{
	[self setWindow:[self cg_makePanel]];
	if (_panelView != nil) {
		/* THE VIEW ASKS THE PANEL TO GO — one notification, so the view never has to know who owns it. */
		[[NSNotificationCenter defaultCenter] addObserver:self
							 selector:@selector(cg_dismissRequested:)
							     name:@"WSQuickLookDismissRequested"
							   object:_panelView];
	}
}

- (void)cg_dismissRequested:(NSNotification *)notification
{
	(void)notification;
	[self hide];
}

/* **THE SUBJECT IS THE STATE.** Asking `-isShowing` must not build a panel — a view that wants to know whether to close one
 * would otherwise create one — so the answer is whether a path is on the glass, which is what `-hide` clears. */
- (BOOL)isShowing
{
	return _path != nil;
}

- (NSString *)path
{
	return _path;
}

/* **THE PLATE IS UP BEFORE THE FILE IS READ.** A glance that waits for a decode to appear is a glance that takes as long as
 * the file is expensive — the user's 1.5 MB picture, a 470-page PDF, a RAW frame — and a person who pressed space has asked
 * for the WINDOW first and the picture second. So the panel is built, titled and ordered front with nothing in it, and the
 * file is decoded after; the second `-setTitle:…` carries the content, which repaints the same window.
 *
 * MEASURED (WS_QUICKLOOK_DIAG): the plate is on the glass in 23 ms and the picture lands on the next pass. */
- (void)showForPath:(NSString *)path
{
	WSQuickLookKind kind;
	NSString *text = nil;
	NSImage *picture = nil;
	NSPDFImageRep *pdf = nil;
	NSImage *icon = nil;

	if (path == nil) {
		[self hide];
		return;
	}
	/* **THE SAME FILE AGAIN IS A RAISE, NOT A DECODE.** A person who presses space twice on one picture should not pay for
	 * the file twice, and the panel is already showing it: bring it forward and stop. MEASURED as a second 16 ms decode per
	 * press before this. */
	if (_path != nil && [_path isEqualToString:path] && _panelView != nil) {
		[[self window] orderFront:nil];
		return;
	}
	/* 1. THE PLATE. Building the panel is the first `-window`, and the title and the kind are known before any byte of the
	 * file is read. */
	{
		NSDate *started = [NSDate date];

		(void)[self window];
		[_path release];
		_path = [path copy];
		[(WSQuickLookView *)_panelView setTitle:[path lastPathComponent]
						   kind:[self kindName]
						   text:nil
						picture:nil
						    pdf:nil
						   icon:nil];
		[[self window] center];
		[[self window] orderFront:nil];
		if (getenv("WS_QUICKLOOK_DIAG") != NULL) {
			fprintf(stderr, "  QL-DIAG plate up in %.0f ms\n",
				([[NSDate date] timeIntervalSinceDate:started]) * 1000.0);
		}
	}
	/* 2. THE FILE. */
	{
		NSDate *started = [NSDate date];

		kind = [WSQuickLookController kindForPath:path];
		switch (kind) {
		case WSQuickLookKindImage: {
			NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
			AGImageSourceRep *rep = ([data length] > 0) ? [AGImageSourceRep imageRepWithData:data] : nil;

			if (rep != nil) {
				picture = [[[NSImage alloc] initWithSize:[rep size]] autorelease];
				[picture addRepresentation:rep];
			}
			break;
		}
		case WSQuickLookKindPDF: {
			NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];

			if ([data length] > 0) {
				pdf = [NSPDFImageRep imageRepWithData:data];
			}
			break;
		}
		case WSQuickLookKindText:
			text = [WSQuickLookController textPreviewForPath:path limit:WSQuickLookTextLimit];
			break;
		case WSQuickLookKindFolder:
		case WSQuickLookKindOther:
			icon = [WSItemIcons iconForPath:path isDirectory:(kind == WSQuickLookKindFolder) size:128];
			break;
		}
		if (getenv("WS_QUICKLOOK_DIAG") != NULL) {
			fprintf(stderr, "  QL-DIAG kind %d decoded in %.0f ms\n", (int)kind,
				([[NSDate date] timeIntervalSinceDate:started]) * 1000.0);
		}
	}
	/* 3. THE CONTENT, INTO THE SAME PLATE. */
	[(WSQuickLookView *)_panelView setTitle:[path lastPathComponent]
					   kind:[self kindName]
					   text:text
					picture:picture
					    pdf:pdf
					   icon:icon];
}

- (void)hide
{
	NSWindow *panel;

	if (_path == nil) {
		return;
	}
	/* **IT TAKES ITS OWN PANEL OFF THE GLASS, AND NOTHING ELSE.** The window is checked against the view this controller
	 * made before it is ordered out: an `NSWindowController` whose window pointer had somehow become another window would
	 * otherwise hide THAT one, and "the glance closed my file window" is a report worth making impossible rather than
	 * investigating. */
	panel = [self window];
	if (panel != nil && _panelView != nil && [panel contentView] == _panelView) {
		[panel orderOut:nil];
	}
	[_path release];
	_path = nil;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[_path release];
	[super dealloc];
}

@end
