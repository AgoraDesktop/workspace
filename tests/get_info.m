/*
 * get_info — the inspector's facts, its window, and the three things the window writes.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE FACTS ARE MEASURED WITHOUT A WINDOW AND THE WINDOW WITHOUT A COMPOSITOR.** `WSItemInfo` is a value: a probe can
 * check the summed bytes of a selection, the mixed-value blanks and the Locked state against a temp tree. The window is
 * built from the AppKit alone, so the fields can be read back — and the three writes (a rename, the Locked box, the
 * comment) are checked on the DISK, because that is what they are for.
 *
 * Nothing here is measured against a picture: the drawing is the compositor's suite's, and this one is about whether the
 * numbers, the names and the writes are right.
 */
#import "WSGetInfoWindowController.h"
#import "WSItemInfo.h"
#import "WSMetadataStore.h"

#import <AppKit/NSButton.h>
#import <AppKit/NSImageView.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTableView.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSTextView.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failed;

static void check(BOOL condition, const char *name)
{
	printf("  [%s] %s\n", condition ? "ok" : "FAIL", name);
	if (!condition) failed++;
}

static BOOL contains(NSString *haystack, NSString *needle)
{
	return haystack != nil && [haystack rangeOfString:needle].location != NSNotFound;
}

static void writeBytes(NSString *path, NSUInteger count)
{
	NSMutableData *data = [NSMutableData dataWithLength:count];

	[data writeToFile:path atomically:NO];
}

static mode_t modeOf(NSString *path)
{
	struct stat s;

	if (stat([path fileSystemRepresentation], &s) != 0) {
		return 0;
	}
	return s.st_mode;
}

int main(void)
{
	@autoreleasepool {
		char template[] = "/tmp/agora-getinfo-XXXXXX";
		char *root = mkdtemp(template);
		NSString *directory;
		NSString *file;
		NSString *other;
		NSString *folder;
		NSString *where;

		if (root == NULL) {
			perror("mkdtemp");
			return 1;
		}
		setvbuf(stdout, NULL, _IONBF, 0);
		directory = [NSString stringWithUTF8String:root];
		where = [directory lastPathComponent];
		printf("get_info: %s\n", root);

		file = [directory stringByAppendingPathComponent:@"note.txt"];
		other = [directory stringByAppendingPathComponent:@"second.txt"];
		folder = [directory stringByAppendingPathComponent:@"folder"];
		writeBytes(file, 100);
		writeBytes(other, 5000);
		[[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES
							   attributes:nil error:NULL];
		writeBytes([folder stringByAppendingPathComponent:@"a"], 10);
		writeBytes([folder stringByAppendingPathComponent:@"b"], 10);

		/* 1. ONE FILE: the facts are the file's. */
		{
			WSItemInfo *info = [WSItemInfo infoForPaths:[NSArray arrayWithObject:file]];

			check(info != nil, "a file has an info");
			check([[info name] isEqual:@"note.txt"], "the name is the file's name");
			check(![info isMultiple], "and it is not a multiple selection");
			check([[info where] isEqual:where], "the Where line is the enclosing folder's name");
			check([info byteCount] == 100, "the byte count is the file's size");
			check([info onDiskByteCount] >= 4096, "and the on-disk size is whole blocks");
			check(![info countsItems], "a file holds no items");
			check([info modificationDate] != nil, "the modification date is read");
			check(![[WSItemInfo dateDescription:[info modificationDate]] isEqual:@"—"],
			      "and it formats as a date");
			check([info kind] != nil && [[info kind] length] > 0, "the kind is answered");
			check([[info permissions] count] == 3, "three permission rows: the owner, the group, everyone");
			check([[info permissionSummary] isEqual:@"You can read and write"],
			      "and the summary says what the owner may do");
			{
				NSString *ownerRow = [[(WSItemPermission *)[[info permissions] objectAtIndex:0] name] copy];

				check([ownerRow rangeOfString:@"(Me)"].location != NSNotFound,
				      "the owner's own row is marked as the person reading it");
				[ownerRow release];
			}
		}

		/* 2. A FOLDER: the kind is "Folder", and the item count is one listing. */
		{
			WSItemInfo *info = [WSItemInfo infoForPaths:[NSArray arrayWithObject:folder]];

			check([[info kind] isEqual:@"Folder"], "a folder's kind is Folder");
			check([info countsItems], "a folder holds items");
			check([info itemCount] == 2, "and the count is what it holds");
			check(contains([WSItemInfo itemCountDescription:[info itemCount]], @"for 2 items"),
			      "which reads as \"for 2 items\"");
		}

		/* 3. A SELECTION: the summable is summed, and the rest is blank rather than guessed. */
		{
			NSArray *paths = [NSArray arrayWithObjects:file, other, nil];
			WSItemInfo *info = [WSItemInfo infoForPaths:paths];

			check([info isMultiple], "two files are a multiple selection");
			check([info count] == 2, "and the count is two");
			check([info name] == nil, "one name for many is blank, not one of the two");
			check([info byteCount] == 5100, "the bytes are summed");
			check([info byteCount] > 0 && [info onDiskByteCount] >= [info byteCount],
			      "and the on-disk total is at least the logical one");
			check([[info where] isEqual:where], "two files in one folder still say where");
			/* A FILE AND A FOLDER: the kinds differ, so there is no single kind — and no item count, because one of
			 * the two is not a folder. */
			info = [WSItemInfo infoForPaths:[NSArray arrayWithObjects:file, folder, nil]];
			check([info kind] == nil, "a file and a folder have no single kind");
			check(![info countsItems], "and no single item count");
		}

		/* 4. THE LOCKED BOX IS THE OWNER'S WRITE BIT, in all three states. */
		{
			WSItemInfo *info;

			(void)chmod([file fileSystemRepresentation], 0644);
			info = [WSItemInfo infoForPaths:[NSArray arrayWithObject:file]];
			check([info lockedState] == NSOffState, "a writable file is not locked");
			(void)chmod([file fileSystemRepresentation], 0444);
			info = [WSItemInfo infoForPaths:[NSArray arrayWithObject:file]];
			check([info lockedState] == NSOnState, "a file with no owner write bit is locked");
			check([[info permissionSummary] isEqual:@"You can only read"], "and the summary says so");
			info = [WSItemInfo infoForPaths:[NSArray arrayWithObjects:file, other, nil]];
			check([info lockedState] == NSMixedState, "a writable file beside a locked one is a mixed state");
			(void)chmod([file fileSystemRepresentation], 0644);
		}

		/* 5. THE STRINGS: the size line has all three parts, and a privilege is a phrase. */
		{
			NSString *line = [WSItemInfo sizeDescriptionForBytes:9731676356ULL onDisk:10444857344ULL];

			printf("  (note: the size line reads \"%s\")\n", [line UTF8String]);
			check(contains(line, @"9,731,676,356 bytes"), "the size line counts the bytes with grouping");
			check(contains(line, @"on disk)"), "and says how much of the disk it takes");
			check([[WSItemInfo privilegeForMode:0644 class:0] isEqual:@"Read & Write"],
			      "an owner's rw is Read & Write");
			check([[WSItemInfo privilegeForMode:0644 class:1] isEqual:@"Read only"],
			      "a group's r is Read only");
			check([[WSItemInfo privilegeForMode:0000 class:2] isEqual:@"No access"],
			      "and no bits at all is No access");
			check([[WSItemInfo dateDescription:nil] isEqual:@"—"], "a missing date is an em dash");
		}

		/* 6. THE WINDOW: six sections, and the fields say what the info says. It is opened the way the shell opens
		 * it — through the registry — because that is the path a person's Get Info takes. */
		{
			WSGetInfoWindowController *window = [WSGetInfoWindowController
				infoWindowForPaths:[NSArray arrayWithObject:file]];

			check(window != nil, "the inspector window is made");
			check([window cg_sectionCount] == 6, "with six sections");
			check([[[window cg_nameField] stringValue] isEqual:@"note.txt"],
			      "the name field starts on the item's name");
			check([[[window cg_kindValue] stringValue] isEqual:[[window info] kind]],
			      "the Kind field says the kind the Launch Services answered");
			check(contains([[window cg_sizeValue] stringValue], @"100 bytes"),
			      "the Size field counts the file's bytes");
			check([[[window cg_whereValue] stringValue] isEqual:where],
			      "and the Where field names the folder");
			/* **NO CREATION DATE, NO ROW.** This substrate records no birth time, so the row is not shown at all — and
			 * the rows under it move up by exactly one row, which is why the window is 17 points shorter than it would
			 * be with the row. */
			check([[window info] creationDate] == nil, "this file system reports no creation time");
			check([[window cg_createdValue] isHidden], "so the Created row is not shown");
			check([[window cg_modifiedValue] frame].origin.y == 3.0 * 17.0,
			      "and Modified has moved up into its place");
			check([[[window cg_modifiedValue] stringValue] isEqual:
				[WSItemInfo dateDescription:[[window info] modificationDate]]],
			      "the Modified field is the date the info read");
			check([[[window cg_permissionTable] tableColumns] count] == 2,
			      "the permissions table has a name column and a privilege column");
			check([[window cg_permissionTable] numberOfRows] == 3, "and three rows");
			check([window cg_lockedButton] != nil && [[window cg_lockedButton] state] == NSOffState,
			      "the Locked box starts unticked for a writable file");

			/* 6b. IT OPENS FOLDED, AND IT FITS ITSELF. Only the first section is open — the rest are a band each —
			 * and the window is exactly as tall as what they make, growing and shrinking as they fold. */
			{
				CGFloat folded = [[[window window] contentView] frame].size.height;
				CGFloat opened;
				CGFloat refolded;
				BOOL restFolded = YES;
				NSUInteger i;

				check(![window cg_isSectionCollapsedAtIndex:0], "the window opens with General open");
				for (i = 1; i < [window cg_sectionCount]; i++) {
					if (![window cg_isSectionCollapsedAtIndex:i]) {
						restFolded = NO;
					}
				}
				check(restFolded, "and every other section folded, so the window is short");
				printf("  (note: the folded window's content is %g points tall\n", (double)folded);
				check(ABS(folded - 319.0) < 0.5,
				      "a folded window is one section tall, less the row this file system has no answer for");

				[window cg_setSectionAtIndex:3 collapsed:NO];
				opened = [[[window window] contentView] frame].size.height;
				printf("  (note: with Comments open it is %g points tall\n", (double)opened);
				check(opened > folded + 40.0, "opening Comments makes the window taller by the section");
				[window cg_setSectionAtIndex:3 collapsed:YES];
				refolded = [[[window window] contentView] frame].size.height;
				check(refolded < folded + 0.5 && refolded > folded - 0.5,
				      "and folding it again puts the window back where it was");

				[window cg_setSectionAtIndex:0 collapsed:YES];
				check([[[window window] contentView] frame].size.height < folded,
				      "folding the last open section shrinks the window to its bands");
				[window cg_setSectionAtIndex:0 collapsed:NO];
			}

			/* 6b2. THE PRIVILEGE IS A CHOICE, AND CHOOSING IS A CHMOD. The column's cell is a pop-up carrying the four
			 * privileges, the row IS the class (owner, group, everyone), and applying one replaces that class's three
			 * bits and leaves the rest of the mode alone. */
			{
				NSMenu *menu = [window cg_privilegeMenuForRow:0];

				check(menu != nil && [menu numberOfItems] == 4,
				      "a click in the privilege column raises four choices");
				check([[[menu itemAtIndex:0] title] isEqual:@"Read & Write"]
				      && [[[menu itemAtIndex:1] title] isEqual:@"Read only"]
				      && [[[menu itemAtIndex:2] title] isEqual:@"Write only"]
				      && [[[menu itemAtIndex:3] title] isEqual:@"No access"],
				      "named the four ways a POSIX mode can answer");
				check([[menu itemAtIndex:1] tag] == 1,
				      "and each item carries the index that is its mode");
				check([[menu itemAtIndex:0] state] == NSOnState
				      && [[menu itemAtIndex:3] state] == NSOffState,
				      "the choice that is true is the one ticked");
				check([window cg_privilegeIndexForRow:0] == 0,
				      "a writable file's owner row starts on Read & Write");

				/* 0600 -> the OWNER's bits only; the group's and everyone's r bits stay as they were. */
				(void)chmod([file fileSystemRepresentation], 0640);
				[window reload];
				check((modeOf(file) & 0777) == 0640, "the file starts at 0640");
				[window cg_applyPrivilegeIndex:3 forRow:0];
				check((modeOf(file) & 0700) == 0, "choosing No access for the owner clears the owner's three bits");
				check((modeOf(file) & 0077) == 0040, "and leaves the group's and everyone's bits alone");
				check([[[window info] permissionSummary] isEqual:@"You have no access"],
				      "the summary follows the mode");
				check([window cg_privilegeIndexForRow:0] == 3, "and the row now says No access");
				check([[[window cg_privilegeMenuForRow:0] itemAtIndex:3] state] == NSOnState,
				      "the menu ticks No access for it");
				[window cg_applyPrivilegeIndex:0 forRow:0];
				check((modeOf(file) & 0700) == 0600, "choosing Read & Write puts the owner's two bits back");
				check((modeOf(file) & 0077) == 0040, "and still leaves the rest alone");
			}

			/* 6c. THE PREVIEW IS THE PICTURE ITSELF: its own shape, and the pane's box on its long side. A text file
			 * has no picture, so it keeps its icon — which is square — and the pane is the box. */
			{
				NSImage *document = [[window cg_previewView] image];
				NSRect pane = [[window cg_previewView] frame];

				check(document != nil, "a document is previewed by its icon");
				check(ABS(pane.size.width - 260.0) < 0.5 && ABS(pane.size.height - 260.0) < 0.5,
				      "and an icon is square, 260 points in the pane");
			}
			{
				NSString *png = [directory stringByAppendingPathComponent:@"wide.png"];
				NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
					initWithBitmapDataPlanes:NULL pixelsWide:200 pixelsHigh:100
					    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
					  colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:200 * 4 bitsPerPixel:32];
				NSData *data = [rep representationUsingType:NSPNGFileType properties:nil];
				WSGetInfoWindowController *picture;
				NSImage *image;

				check(data != nil && [data writeToFile:png atomically:NO],
				      "a 200x100 PNG is written for the preview to read");
				[rep release];
				picture = [WSGetInfoWindowController infoWindowForPaths:[NSArray arrayWithObject:png]];
				image = [[picture cg_previewView] image];
				check(image != nil, "an image file is previewed by its own picture");
				printf("  (note: the preview is %gx%g points in a 260 pane\n",
				       (double)[image size].width, (double)[image size].height);
				check([image size].width > [image size].height * 1.8,
				      "at the picture's own shape, not squared off with transparent bands");
				check(ABS([image size].width - 260.0) < 2.0
				      && ABS([image size].height - 130.0) < 2.0,
				      "fitted into the pane's box on its long side, without stretching");
				check(ABS(([[picture cg_previewView] frame]).size.height - 130.0) < 2.0,
				      "and the view is the picture's height, so the pane does not leave a white lake");
			}

			/* 7. TWO WINDOWS ON ONE SUBJECT ARE ONE WINDOW. */
			{
				WSGetInfoWindowController *again = [WSGetInfoWindowController
					infoWindowForPaths:[NSArray arrayWithObject:file]];
				WSGetInfoWindowController *different = [WSGetInfoWindowController
					infoWindowForPaths:[NSArray arrayWithObject:other]];

				check(again == window,
				      "asking again for the same item reuses the window that is open on it");
				check(different != nil && ![different cg_isShowingPaths:[window paths]],
				      "and a different item is a different window");
				check([[WSGetInfoWindowController cg_openInfoWindows] count] == 3,
				      "the registry holds exactly the three that were opened");
			}

			/* 8. THE COMMENT IS THE SIDECAR'S, written as it is typed. */
			{
				NSString *comment = @"A note about this file.";
				WSMetadataStore *store;

				[[window cg_commentsView] setString:comment];
				[[NSNotificationCenter defaultCenter]
					postNotificationName:NSTextDidChangeNotification
						      object:[window cg_commentsView]];
				store = [WSMetadataStore storeForDirectory:directory];
				check([[store commentForName:@"note.txt"] isEqual:comment],
				      "a typed comment is in the folder's sidecar");
			}

			/* 9. THE LOCKED BOX WRITES THE MODE, keeping every other bit. */
			if ([window cg_lockedButton] != nil) {
				[[window cg_lockedButton] setState:NSOnState];
				[[window cg_lockedButton] sendAction:[[window cg_lockedButton] action]
								  to:[[window cg_lockedButton] target]];
				check((modeOf(file) & S_IWUSR) == 0, "ticking Locked clears the owner's write bit");
				[[window cg_lockedButton] setState:NSOffState];
				[[window cg_lockedButton] sendAction:[[window cg_lockedButton] action]
								  to:[[window cg_lockedButton] target]];
				check((modeOf(file) & S_IWUSR) != 0, "and unticking it puts the bit back");
			}

			/* 10. THE NAME FIELD RENAMES THE FILE — and the comment goes with the name. */
			{
				NSString *renamed = [directory stringByAppendingPathComponent:@"renamed.txt"];

				[[window cg_nameField] setStringValue:@"renamed.txt"];
				[[window cg_nameField] sendAction:[[window cg_nameField] action]
							      to:[[window cg_nameField] target]];
				check([[NSFileManager defaultManager] fileExistsAtPath:renamed],
				      "typing a new name and pressing Return renames the file");
				check(![[NSFileManager defaultManager] fileExistsAtPath:file],
				      "and the old name is gone");
				check([[[window info] name] isEqual:@"renamed.txt"],
				      "the window now says the new name");
				{
					WSMetadataStore *store = [WSMetadataStore storeForDirectory:directory];

					check([[store commentForName:@"renamed.txt"] isEqual:@"A note about this file."],
					      "and the comment moved with it");
					check([store commentForName:@"note.txt"] == nil,
					      "leaving nothing filed under the old name");
				}
				/* A NAME THAT IS NOT A NAME IS REFUSED, and the field goes back to what is on the disk. */
				[[window cg_nameField] setStringValue:@"no/slash"];
				[[window cg_nameField] sendAction:[[window cg_nameField] action]
							      to:[[window cg_nameField] target]];
				check([[[window cg_nameField] stringValue] isEqual:@"renamed.txt"],
				      "a name with a slash in it is refused and the field says the real name");
			}
			/* NOT RELEASED: the registry owns both windows, which is what makes a Get Info window outlive the
			 * click that opened it. */
		}

		printf("get_info: %d case(s) failed\n", failed);
		{
			char command[4096];

			snprintf(command, sizeof command, "rm -rf '%s'", root);
			(void)system(command);
		}
	}
	return failed == 0 ? 0 : 1;
}
