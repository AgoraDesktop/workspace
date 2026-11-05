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
static const CGFloat WSQuickLookHeaderGrey = 0.26;
static const CGFloat WSQuickLookInk = 0.92;

/* ============================================================================================ *
 * THE VIEW                                                                                      *
 * ============================================================================================ */

@interface WSQuickLookView : NSView
{
	NSString *_title;	/* RETAINED: the file's name */
	NSString *_kind;	/* RETAINED: what the panel calls it, and its size */
	NSString *_text;	/* RETAINED: the preview text, or nil */
	NSImage *_picture;	/* RETAINED: an image file */
	NSPDFImageRep *_pdf;	/* RETAINED: a document, drawn as one vector page */
	NSImage *_icon;		/* RETAINED: a folder's or a plain file's own icon */
}
- (void)setTitle:(nullable NSString *)title kind:(nullable NSString *)kind text:(nullable NSString *)text
	 picture:(nullable NSImage *)picture pdf:(nullable NSPDFImageRep *)pdf icon:(nullable NSImage *)icon;
@end

/* **THE VIEW IS NOT FLIPPED, AND SAYS SO.** Every rectangle below is derived from `-bounds` with y UP — the strip at the
 * top is `height - header`, the hint at the bottom is a few points above zero. That is the orientation the window's own
 * content view has, and a view that guessed the other way put its title strip along the bottom edge and squared off the
 * rounded corners it crossed. MEASURED: the plate's bottom corners came out opaque grey where the strip had been painted
 * over them. */
@implementation WSQuickLookView

- (BOOL)isFlipped
{
	return NO;
}

- (void)dealloc
{
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

/* **A GLANCE IS DISMISSED BY A CLICK ON IT**, which is what Finder's panel does and what a person tries first. */
- (void)mouseDown:(NSEvent *)event
{
	(void)event;
	[[NSNotificationCenter defaultCenter] postNotificationName:@"WSQuickLookDismissRequested" object:self];
}

/* THE INSETS THE WHOLE PANEL IS LAID OUT IN: a header band at the top, a footer band at the bottom, and the same margin
 * on the left and right so the content, the title and the hint share one edge. */
static const CGFloat WSQuickLookHeader = 34.0;
static const CGFloat WSQuickLookFooter = 22.0;
static const CGFloat WSQuickLookMargin = 12.0;
static const CGFloat WSQuickLookCorner = 12.0;

- (NSRect)cg_headerRect
{
	NSRect bounds = [self bounds];

	return NSMakeRect(0.0, NSHeight(bounds) - WSQuickLookHeader, NSWidth(bounds), WSQuickLookHeader);
}

- (NSRect)cg_footerRect
{
	return NSMakeRect(0.0, 0.0, NSWidth([self bounds]), WSQuickLookFooter);
}

- (NSRect)cg_contentRect
{
	NSRect bounds = [self bounds];

	return NSMakeRect(WSQuickLookMargin, WSQuickLookFooter,
			  NSWidth(bounds) - 2.0 * WSQuickLookMargin,
			  NSHeight(bounds) - WSQuickLookHeader - WSQuickLookFooter);
}

- (NSDictionary *)cg_titleAttributes
{
	NSMutableDictionary *attributes = [NSMutableDictionary dictionary];

	[attributes setObject:[NSFont boldSystemFontOfSize:13.0] forKey:NSFontAttributeName];
	[attributes setObject:[NSColor colorWithCalibratedWhite:WSQuickLookInk alpha:1.0]
		       forKey:NSForegroundColorAttributeName];
	return attributes;
}

- (NSDictionary *)cg_secondaryAttributes
{
	NSMutableDictionary *attributes = [NSMutableDictionary dictionary];

	[attributes setObject:[NSFont systemFontOfSize:11.0] forKey:NSFontAttributeName];
	[attributes setObject:[NSColor colorWithCalibratedWhite:0.58 alpha:1.0] forKey:NSForegroundColorAttributeName];
	return attributes;
}

/* THE PLATE: the rounded body, the header band clipped to it, and a hairline where the two meet. The header is drawn as a
 * CLIPPED RECTANGLE rather than a second rounded path, so its own corners are the plate's. */
- (void)drawPlate
{
	NSRect bounds = [self bounds];
	NSRect header = [self cg_headerRect];
	NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:WSQuickLookCorner
							       yRadius:WSQuickLookCorner];

	[[NSColor colorWithCalibratedWhite:WSQuickLookPlate alpha:1.0] setFill];
	[plate fill];
	[NSGraphicsContext saveGraphicsState];
	[plate addClip];
	[[NSColor colorWithCalibratedWhite:WSQuickLookHeaderGrey alpha:1.0] setFill];
	[[NSBezierPath bezierPathWithRect:header] fill];
	[[NSColor colorWithCalibratedWhite:0.34 alpha:1.0] setStroke];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, NSMinY(header), NSWidth(bounds), 1.0)] stroke];
	[NSGraphicsContext restoreGraphicsState];
	/* AND THE EDGE OF THE PLATE ITSELF, a hairline lighter than either band so the panel has a boundary against a dark
	 * desktop as well as a light one. */
	[[NSColor colorWithCalibratedWhite:0.38 alpha:1.0] setStroke];
	[[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:WSQuickLookCorner
					  yRadius:WSQuickLookCorner] stroke];
}

- (void)drawHeader
{
	NSRect header = [self cg_headerRect];

	if (_title != nil) {
		[[self cg_titleAttributes] count];
		[_title drawInRect:NSMakeRect(NSMinX(header) + WSQuickLookMargin, NSMinY(header) + 9.0,
					      NSWidth(header) - 2.0 * WSQuickLookMargin - 220.0, 17.0)
		    withAttributes:[self cg_titleAttributes]];
	}
	if (_kind != nil) {
		[_kind drawInRect:NSMakeRect(NSWidth(header) - 220.0, NSMinY(header) + 11.0, 208.0, 15.0)
		    withAttributes:[self cg_secondaryAttributes]];
	}
}

- (void)drawFooter
{
	NSRect footer = [self cg_footerRect];

	[@"Space or Esc closes" drawInRect:NSMakeRect(NSWidth(footer) - 150.0, 6.0, 138.0, 14.0)
			    withAttributes:[self cg_secondaryAttributes]];
}

/* THE PICTURE, FITTED AND CENTRED, WITH A HAIRLINE ROUND IT so a white photograph is not a hole in the plate. */
- (void)drawPicture:(NSImage *)picture inRect:(NSRect)content
{
	NSSize size;
	CGFloat scale;
	NSRect frame;

	if (picture == nil || NSWidth(content) <= 0.0 || NSHeight(content) <= 0.0) {
		return;
	}
	size = [picture size];
	if (size.width <= 0.0 || size.height <= 0.0) {
		return;
	}
	scale = NSWidth(content) / size.width;
	if (NSHeight(content) / size.height < scale) {
		scale = NSHeight(content) / size.height;
	}
	frame = NSMakeRect(NSMidX(content) - size.width * scale / 2.0,
			   NSMidY(content) - size.height * scale / 2.0,
			   size.width * scale, size.height * scale);
	[picture drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
	      respectFlipped:NO hints:nil];
	[[NSColor colorWithCalibratedWhite:0.34 alpha:1.0] setStroke];
	[[NSBezierPath bezierPathWithRect:NSInsetRect(frame, -0.5, -0.5)] stroke];
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSRect content = [self cg_contentRect];

	(void)dirtyRect;
	[self drawPlate];
	[self drawHeader];
	[self drawFooter];
	if (_picture != nil) {
		[self drawPicture:_picture inRect:content];
		return;
	}
	if (_pdf != nil) {
		NSRect page = [_pdf bounds];
		CGFloat scale;
		NSRect frame;

		if (page.size.width <= 0.0 || page.size.height <= 0.0) {
			return;
		}
		scale = NSWidth(content) / page.size.width;
		if (NSHeight(content) / page.size.height < scale) {
			scale = NSHeight(content) / page.size.height;
		}
		frame = NSMakeRect(NSMidX(content) - page.size.width * scale / 2.0,
				   NSMidY(content) - page.size.height * scale / 2.0,
				   page.size.width * scale, page.size.height * scale);
		/* THE PAGE'S PAPER FIRST: a PDF draws nothing in its margins and the plate would show through every page. */
		[[NSColor whiteColor] setFill];
		[[NSBezierPath bezierPathWithRect:frame] fill];
		[_pdf drawInRect:frame];
		[[NSColor colorWithCalibratedWhite:0.34 alpha:1.0] setStroke];
		[[NSBezierPath bezierPathWithRect:NSInsetRect(frame, -0.5, -0.5)] stroke];
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
		if (size.width > 0.0 && size.height > 0.0) {
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
	/* 3. THE CONTENT, INTO THE SAME PLATE. **AND THE SIZE GOES IN THE HEADER WITH THE KIND**, because a glance's second
	 * question after "what is it" is "how big is it", and "Image · 1920 × 1080" answers both in one line. */
	{
		NSString *kindText = [self kindName];
		NSSize size = NSZeroSize;

		if (picture != nil) {
			size = [picture size];
		} else if (pdf != nil) {
			size = [pdf bounds].size;
		}
		if (size.width > 0.0 && size.height > 0.0) {
			kindText = [NSString stringWithFormat:@"%@ · %.0f × %.0f", kindText, (double)size.width,
				    (double)size.height];
		}
		[(WSQuickLookView *)_panelView setTitle:[path lastPathComponent]
						   kind:kindText
						   text:text
						picture:picture
						    pdf:pdf
						   icon:icon];
	}
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
