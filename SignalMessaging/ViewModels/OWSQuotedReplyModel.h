//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "CVItemViewModel.h"
#import <SignalServiceKit/TSQuotedMessage.h>

NS_ASSUME_NONNULL_BEGIN

@class ContactShareViewModel;
@class MessageBodyRanges;
@class OWSLinkPreview;
@class SDSAnyReadTransaction;
@class SignalServiceAddress;
@class StickerInfo;
@class StickerMetadata;
@class TSAttachment;
@class TSAttachmentPointer;
@class TSAttachmentStream;
@class TSInteraction;
@class TSMessage;

@protocol CVItemViewModelImpl;

// View model which has already fetched any attachments.
@interface OWSQuotedReplyModel : NSObject

@property (nonatomic, readonly) uint64_t timestamp;
@property (nonatomic, readonly) SignalServiceAddress *authorAddress;
@property (nonatomic, readonly, nullable) TSAttachmentStream *attachmentStream;
@property (nonatomic, readonly, nullable) TSAttachmentPointer *failedThumbnailAttachmentPointer;

// This property should be set IFF we are quoting a text message
// or attachment with caption.
@property (nullable, nonatomic, readonly) NSString *body;
@property (nullable, nonatomic, readonly) MessageBodyRanges *bodyRanges;
@property (nonatomic, readonly) BOOL isRemotelySourced;

#pragma mark - Attachments

// This is a MIME type.
//
// This property should be set IFF we are quoting an attachment message.
@property (nonatomic, readonly, nullable) NSString *contentType;
@property (nonatomic, readonly, nullable) NSString *sourceFilename;
@property (nonatomic, readonly, nullable) UIImage *thumbnailImage;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

// Used for persisted quoted replies, both incoming and outgoing.
+ (nullable instancetype)quotedReplyFromMessage:(TSMessage *)message transaction:(SDSAnyReadTransaction *)transaction;

// Builds a not-yet-sent QuotedReplyModel
+ (nullable instancetype)quotedReplyForSendingWithItem:(id<CVItemViewModel>)item
                                           transaction:(SDSAnyReadTransaction *)transaction;

- (TSQuotedMessage *)buildQuotedMessageForSending;


@end

NS_ASSUME_NONNULL_END
