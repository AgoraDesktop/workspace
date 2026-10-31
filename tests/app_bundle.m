/*
 * app_bundle — an application bundle is one thing, wherever it sits.
 */
#import "WSFileWindowController.h"
#import "WSIconView.h"
#import "WSItemIcons.h"
#import "WSItemKind.h"
#import "WSItemModel.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

static int s_failed = 0;
static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) s_failed++;
}

static BOOL write_text(NSString *path, NSString *text)
{
	return [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static BOOL wait_for(NSString *path, int ms)
{
	int waited = 0;
	while (waited < ms) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
		usleep(20 * 1000);
		waited += 20;
	}
	return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

/* **THE ICON'S PIXELS, PAINTED INTO A BITMAP.** `-TIFFRepresentation` is not a door this tier's `NSImage` promises, so a
 * nil there would read as "no icon" when the icon is perfectly good — the picture is what the question is about. */
static NSData *icon_pixels(NSString *path, BOOL isDirectory)
{
	NSImage *image = [WSItemIcons iconForPath:path isDirectory:isDirectory size:64];
	NSBitmapImageRep *rep;
	NSGraphicsContext *context;

	if (image == nil) {
		return nil;
	}
	rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:64 pixelsHigh:64
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:64 * 4 bitsPerPixel:32];
	context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:context];
	[[NSColor whiteColor] setFill];
	[[NSBezierPath bezierPathWithRect:NSMakeRect(0.0, 0.0, 64.0, 64.0)] fill];
	[image drawInRect:NSMakeRect(0.0, 0.0, 64.0, 64.0)];
	[NSGraphicsContext restoreGraphicsState];
	{
		NSData *data = [NSData dataWithBytes:[rep bitmapData] length:(NSUInteger)(64 * 4 * 64)];

		[rep release];
		return data;
	}
}

int main(void)
{
	@autoreleasepool {
		NSString *root = [NSString stringWithFormat:@"/tmp/workspace-app-bundle-%d", (int)getpid()];
		NSString *deep = [root stringByAppendingPathComponent:@"deep/Some Place"];
		NSString *bundle = [deep stringByAppendingPathComponent:@"Thing.app"];
		NSString *contents = [bundle stringByAppendingPathComponent:@"Contents"];
		NSString *macos = [contents stringByAppendingPathComponent:@"MacOS"];
		NSString *exe = [macos stringByAppendingPathComponent:@"Thing"];
		NSString *marker = [root stringByAppendingPathComponent:@"ran.txt"];
		NSString *plainRoot = [root stringByAppendingPathComponent:@"plain"];
		NSString *plain = [plainRoot stringByAppendingPathComponent:@"Plain Folder"];
		NSString *manifest = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
			"<plist version=\"1.0\"><dict>"
			"<key>CFBundleIdentifier</key><string>com.agora.app-bundle-probe</string>"
			"<key>CFBundleExecutable</key><string>Thing</string>"
			"<key>CFBundlePackageType</key><string>APPL</string>"
			"<key>CFBundleName</key><string>Thing</string>"
			"</dict></plist>\n";
		NSFileManager *manager = [NSFileManager defaultManager];

		setvbuf(stdout, NULL, _IONBF, 0);
		(void)[[NSApplication sharedApplication] finishLaunching];
		[manager removeItemAtPath:root error:NULL];

		check([manager createDirectoryAtPath:macos withIntermediateDirectories:YES attributes:nil error:NULL]
		      && [manager createDirectoryAtPath:plain withIntermediateDirectories:YES attributes:nil error:NULL],
		      "the probe built a deep folder with a bundle, and a plain folder elsewhere");
		check(write_text([contents stringByAppendingPathComponent:@"Info.plist"], manifest)
		      && write_text(exe, @"#!/bin/sh\nprintf ran > \"$AGORA_PROBE_OUT\"\n")
		      && chmod([exe UTF8String], 0755) == 0,
		      "and a bundle with a runnable executable");

		{
			WSItem *item = [[[WSItem alloc] initWithName:@"Thing.app" path:bundle isDirectory:YES] autorelease];
			WSItem *folder = [[[WSItem alloc] initWithName:@"Plain Folder" path:plain isDirectory:YES] autorelease];
			NSString *kind;

			check([item isPackage] && ![item isBrowsable],
			      "a bundle in a deep folder is a package, not a place to browse into");
			kind = [WSItemKind kindForItem:item];
			printf("  [diag] path %s, kind %s\n", [bundle UTF8String], [kind UTF8String]);
			check(kind != nil && [[kind lowercaseString] rangeOfString:@"application"].location != NSNotFound,
			      "its Kind says Application");
			check([[WSItemKind kindForItem:folder] isEqual:@"Folder"],
			      "and a plain folder still says Folder");

			{
				NSData *bundleIcon = icon_pixels(bundle, YES);
				NSData *folderIcon = icon_pixels(plain, YES);

				check(bundleIcon != nil, "the bundle has an icon");
				check(folderIcon != nil, "so does the plain folder");
				check(bundleIcon != nil && folderIcon != nil && ![bundleIcon isEqual:folderIcon],
				      "and they are NOT the same picture — a bundle does not wear the folder's face");
				check([[item name] isEqual:@"Thing.app"], "the item's name is the name on disk");
			}
		}

		/* **AND THE RULE IS ABOUT THE NAME, NOT ABOUT WHAT IS INSIDE.** Two directories a person would call an
		 * application and this tree did not: one spelled `Upper.APP`, and one whose `Contents` has not been written yet
		 * (a bundle being assembled, an export that failed halfway). macOS treats both as bundles — the extension is what
		 * a bundle is, and a bundle is one thing rather than a place — while the package question here was answered by a
		 * case-SENSITIVE extension match AND by the presence of a `Contents` child. */
		{
			NSString *upper = [deep stringByAppendingPathComponent:@"Upper.APP"];
			NSString *bare = [deep stringByAppendingPathComponent:@"Bare.app"];

			check([manager createDirectoryAtPath:upper withIntermediateDirectories:YES attributes:nil error:NULL]
			      && [manager createDirectoryAtPath:bare withIntermediateDirectories:YES attributes:nil error:NULL],
			      "the probe built a bundle spelled in capitals and one with nothing inside yet");
			{
				WSItem *upperItem = [[[WSItem alloc] initWithName:@"Upper.APP" path:upper isDirectory:YES] autorelease];
				WSItem *bareItem = [[[WSItem alloc] initWithName:@"Bare.app" path:bare isDirectory:YES] autorelease];

				check([upperItem isPackage] && ![upperItem isBrowsable],
				      "a bundle spelled Upper.APP is still a bundle");
				check([bareItem isPackage] && ![bareItem isBrowsable],
				      "and so is a Bare.app whose Contents has not been written yet");
				/* **AND THE KIND COLUMN STILL READS AS AN APPLICATION**, from Launch Services' registration of the
				 * extension rather than from the bundle's own Info.plist — which is what makes a half-written bundle
				 * describe itself correctly before it can run. */
				{
					NSString *bareKind = [WSItemKind kindForItem:bareItem];

					check(bareKind != nil
					      && [[bareKind lowercaseString] rangeOfString:@"application"].location != NSNotFound,
					      "a Bare.app's Kind still reads as an application");
				}
			}
			[manager removeItemAtPath:upper error:NULL];
			[manager removeItemAtPath:bare error:NULL];
		}

		{
			WSFileWindowController *windowController = [[WSFileWindowController alloc] initWithDirectory:deep];
			WSIconView *icons;

			check([windowController itemCount] == 1, "the window lists the bundle");
			setenv("AGORA_PROBE_OUT", [marker UTF8String], 1);
			icons = [windowController cg_iconView];
			{
				NSPoint inWindow = [icons convertPoint:NSMakePoint(30.0, 30.0) toView:nil];
				NSEvent *down = [NSEvent mouseEventWithType:NSLeftMouseDown location:inWindow
							       modifierFlags:0 timestamp:0.0 windowNumber:0 context:nil
							      eventNumber:0 clickCount:2 pressure:1.0f];

				[icons mouseDown:down];
			}
			check([[windowController directory] isEqual:deep], "double-clicking it does not descend into Contents");
			check(wait_for(marker, 3000), "it RAN");
			/* **AND THE TREE TREATS IT AS ONE THING TOO.** A bundle that is a leaf to a double-click must be a leaf to a
			 * disclosure triangle, or List mode offers to open what the icon grid refuses to. */
			[windowController cg_useListView:nil];
			{
				WSListView *list = [windowController cg_listView];
				WSItem *row = [list cg_itemForPath:bundle];

				check(row != nil && ![list outlineView:list isItemExpandable:row],
				      "and in List mode it is one row with no disclosure triangle");
			}
			[windowController close];
			[windowController release];
		}

		[manager removeItemAtPath:root error:NULL];
	}
	printf(s_failed == 0 ? "app_bundle: all checks passed\n" : "app_bundle: FAILURES\n");
	return s_failed == 0 ? 0 : 1;
}
