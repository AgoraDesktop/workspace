/*
 * WSAboutPanel.m — the About panel: the application's icon, its name, its version, and what it is.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed — see LICENSE.
 * SPDX-License-Identifier: MIT
 *
 * **EVERY STRING IN IT COMES FROM THE BUNDLE.** `CFBundleName`, `CFBundleShortVersionString` and
 * `CFBundleIdentifier` are read out of `Contents/Info.plist` through `-[NSBundle objectForInfoDictionaryKey:]`, so
 * the box cannot come to disagree with the bundle it is describing — the version in the About box IS the version
 * `libagora-launchservices` reads when it launches the application. A value that is missing falls back to the
 * process's own name rather than to an empty line.
 */
#import "WSAboutPanel.h"

#import <AppKit/NSAttributedString.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSStringDrawing.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSString.h>

#import <IconServices/IconServices.h>

#include <CoreGraphics/CGImage.h>

static NSWindow *s_aboutPanel = nil;

/* ONE FALLBACK RULE FOR THE WHOLE PANEL: an Info.plist value, or the answer the caller named. */
static NSString *WSBundleString(NSString *key, NSString *fallback)
{
	id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:key];

	return (value != nil && [value isKindOfClass:[NSString class]]) ? (NSString *)value : fallback;
}

/* **THE ATTRIBUTES ARE BUILT RATHER THAN WRITTEN AS A LITERAL, BECAUSE A FONT MAY BE NIL.** A dictionary literal
 * that named a nil font would be a dictionary built by a variadic that stops at the first nil — the trap
 * `NSDictionary +dictionaryWithObjectsAndKeys:` sets and that this tree's own code comments on. */
static NSDictionary *WSTextAttributes(CGFloat size, BOOL bold, NSColor *colour)
{
	NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
	NSFont *font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];

	if (font != nil) {
		[attributes setObject:font forKey:NSFontAttributeName];
	}
	if (colour != nil) {
		[attributes setObject:colour forKey:NSForegroundColorAttributeName];
	}
	return attributes;
}

@interface WSAboutView : NSView
@end

@implementation WSAboutView

- (BOOL)isOpaque { return YES; }

/* **ONE LINE, CENTRED, AND THE CENTRING IS GEOMETRIC.** `-drawInRect:withAttributes:` does NOT honour a paragraph
 * style's alignment — MEASURED, in `WSDesktopView`, where `NSCenterTextAlignment` left the text where it was — so
 * the rectangle handed to it is exactly as wide as the measured string and placed at the middle. `top` counts DOWN
 * from the view's top edge, which is what a panel's layout reads as. */
static void WSDrawCentredLine(NSString *text, NSRect bounds, NSDictionary *attributes, CGFloat top)
{
	NSSize size = [text sizeWithAttributes:attributes];
	/* **ROUNDED UP, BECAUSE A RECT EXACTLY AS WIDE AS THE ADVANCE CLIPS THE LAST GLYPH.** The clock and the AppKit
	 * cells needed the same point; see `WSMenuBarClock.m` for the measurement. */
	CGFloat width = ceil(size.width);
	CGFloat height = ceil(size.height);
	NSRect line = NSMakeRect((bounds.size.width - width) / 2.0,
				 bounds.size.height - top - height, width, height);

	[text drawInRect:line withAttributes:attributes];
}

/* THE APPLICATION'S OWN ICON, through the same door the desktop uses for an item's. The bundle IS a directory, which
 * is what the last argument says. */
static void WSDrawApplicationIcon(NSRect bounds)
{
	const CGFloat side = 64.0;
	NSString *path = [[NSBundle mainBundle] bundlePath];
	CFStringRef cPath;
	CFURLRef url;
	IconRef icon;
	CGImageRef image;
	NSBitmapImageRep *rep;
	NSRect box = NSMakeRect((bounds.size.width - side) / 2.0, bounds.size.height - 26.0 - side, side, side);

	if (path == nil) {
		return;
	}
	cPath = CFStringCreateWithCString(NULL, [path UTF8String], kCFStringEncodingUTF8);
	url = CFURLCreateWithFileSystemPath(NULL, cPath, kCFURLPOSIXPathStyle, true);
	CFRelease(cPath);

	icon = AGIconCreateWithURL(url);
	CFRelease(url);
	if (icon == NULL) {
		return;
	}
	image = AGIconCopyImage(icon, CGSizeMake(side, side));
	AGIconRelease(icon);
	if (image == NULL) {
		return;
	}
	rep = [NSBitmapImageRep imageRepWithCGImage:image];
	CGImageRelease(image);
	if (rep != nil) {
		[rep drawInRect:box];
	}
}

- (void)drawRect:(NSRect)dirtyRect
{
	NSRect bounds = [self bounds];
	NSString *name = WSBundleString(@"CFBundleName", [[NSProcessInfo processInfo] processName]);
	NSString *version = WSBundleString(@"CFBundleShortVersionString", @"0.0");
	NSString *identifier = WSBundleString(@"CFBundleIdentifier", @"");
	NSColor *grey = [NSColor darkGrayColor];

	(void)dirtyRect;

	[[NSColor windowBackgroundColor] setFill];
	[[NSBezierPath bezierPathWithRect:bounds] fill];

	WSDrawApplicationIcon(bounds);

	WSDrawCentredLine(name, bounds, WSTextAttributes(15.0, YES, [NSColor blackColor]), 104.0);
	WSDrawCentredLine([NSString stringWithFormat:@"Version %@", version], bounds,
			  WSTextAttributes(12.0, NO, [NSColor blackColor]), 126.0);

	/* THE HAIRLINE, the way every About box divides the name from the credit. */
	[[NSColor lightGrayColor] setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(24.0, bounds.size.height - 152.0, bounds.size.width - 48.0, 1.0)]
		fill];

	WSDrawCentredLine(@"Agora's file manager and desktop.", bounds, WSTextAttributes(11.0, NO, [NSColor blackColor]),
			  162.0);
	WSDrawCentredLine(@"© 2026 Kyle J. Cardoza. MIT licensed.", bounds, WSTextAttributes(10.0, NO, grey), 182.0);
	if ([identifier length] > 0) {
		WSDrawCentredLine(identifier, bounds, WSTextAttributes(9.0, NO, grey), 202.0);
	}
}

@end

@implementation WSAboutPanel

+ (void)orderFront
{
	if (s_aboutPanel == nil) {
		NSRect frame = NSMakeRect(0.0, 0.0, 320.0, 240.0);
		NSWindow *panel = [[NSWindow alloc] initWithContentRect:frame
							     styleMask:NSTitledWindowMask | NSClosableWindowMask
							       backing:NSBackingStoreBuffered
								 defer:NO];

		if (panel == nil) {
			return;
		}
		[panel setTitle:[NSString stringWithFormat:@"About %@",
				 WSBundleString(@"CFBundleName", [[NSProcessInfo processInfo] processName])]];
		[panel setContentView:[[[WSAboutView alloc] initWithFrame:frame] autorelease]];
		s_aboutPanel = panel;
	}
	[s_aboutPanel center];
	[s_aboutPanel makeKeyAndOrderFront:nil];
}

@end
