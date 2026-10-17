/*
 * metadata_store — W1's other offscreen measurement: the per-folder sidecar.
 *
 * Copyright © 2026 Kyle J. Cardoza. MIT licensed. SPDX-License-Identifier: MIT
 *
 * THE SIDECAR IS WRITTEN, REOPENED AND READ BACK, and a sidecar from a version this build does not know is
 * refused WHOLE rather than read field by field — because a person's icon positions are the thing a bad read
 * would silently scramble.
 */
#import "WSMetadataStore.h"

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>

static int failed;

static void check(BOOL condition, const char *name)
{
	printf("  [%s] %s\n", condition ? "ok" : "FAIL", name);
	if (!condition) failed++;
}

int main(void)
{
	@autoreleasepool {
		char template[] = "/tmp/agora-metadata-XXXXXX";
		char *root = mkdtemp(template);
		NSString *directory;
		WSMetadataStore *store, *again, *third, *fourth, *foreign;
		NSPoint position;
		NSDictionary *future;
		NSData *data;
		char command[4096];

		if (root == NULL) { perror("mkdtemp"); return 1; }
		directory = [NSString stringWithUTF8String:root];
		printf("metadata_store: %s\n", root);

		store = [WSMetadataStore storeForDirectory:directory];
		check(store != nil, "a store is made for a directory with no sidecar");
		check(![store hasIconPositionForName:@"a"], "and nothing has a position yet");

		[store setIconPosition:NSMakePoint(12.0, 34.0) forName:@"a"];
		[store setIconPosition:NSMakePoint(56.0, 78.0) forName:@"b"];
		[store setIconSize:96];
		check([store save], "the sidecar is written");

		again = [WSMetadataStore storeForDirectory:directory];
		check([again hasIconPositionForName:@"a"], "a reopened store remembers a position");
		position = [again iconPositionForName:@"a"];
		check(position.x == 12.0 && position.y == 34.0, "and the value is the one that was written");
		check([again hasIconPositionForName:@"b"], "and the second item's too");
		check([again iconSize] == 96, "and the icon size");

		[again setIconPosition:NSMakePoint(1.0, 2.0) forName:@"c"];
		check([again save], "and it writes again with a new item");
		third = [WSMetadataStore storeForDirectory:directory];
		check([third hasIconPositionForName:@"b"] && [third hasIconPositionForName:@"c"],
		      "a third read sees both the old and the new");

		[third removeIconPositionForName:@"b"];
		check([third save], "a removal is written");
		fourth = [WSMetadataStore storeForDirectory:directory];
		check(![fourth hasIconPositionForName:@"b"], "the removed position stays removed");
		check([fourth hasIconPositionForName:@"c"], "and the others are untouched");

		/* A sidecar from a version this build does not know: refused WHOLE. */
		future = [NSDictionary dictionaryWithObjectsAndKeys:
				[NSNumber numberWithInteger:99], @"version",
				[NSDictionary dictionaryWithObjectsAndKeys:
					[NSArray arrayWithObjects:[NSNumber numberWithDouble:5.0],
								  [NSNumber numberWithDouble:6.0], nil], @"x",
					nil], @"icons",
				nil];
		data = [NSPropertyListSerialization dataWithPropertyList:future
								  format:NSPropertyListXMLFormat_v1_0
								 options:0
								   error:NULL];
		[data writeToFile:[directory stringByAppendingPathComponent:@".agora"] atomically:YES];
		foreign = [WSMetadataStore storeForDirectory:directory];
		check(![foreign hasIconPositionForName:@"x"], "a sidecar from an unknown version is refused whole");

		printf("metadata_store: %d case(s) failed\n", failed);
		snprintf(command, sizeof command, "rm -rf '%s'", root);
		(void)system(command);
	}
	return failed == 0 ? 0 : 1;
}
