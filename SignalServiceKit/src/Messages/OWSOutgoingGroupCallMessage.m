//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import <SignalServiceKit/OWSOutgoingGroupCallMessage.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

@interface OWSOutgoingGroupCallMessage ()
@property (strong, nonatomic, nullable) NSString *eraId;
@end

@implementation OWSOutgoingGroupCallMessage

- (instancetype)initWithThread:(TSGroupThread *)thread eraId:(nullable NSString *)eraId
{
    OWSAssertDebug(thread);

    TSOutgoingMessageBuilder *messageBuilder = [TSOutgoingMessageBuilder outgoingMessageBuilderWithThread:thread];
    self = [super initOutgoingMessageWithBuilder:messageBuilder];
    if (self) {
        _eraId = eraId;
    }
    return self;
}

- (BOOL)shouldBeSaved
{
    return NO;
}

- (nullable SSKProtoDataMessageBuilder *)dataMessageBuilderWithThread:(TSThread *)thread
                                                          transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(thread.isGroupThread);

    NSError *_Nullable error = nil;
    SSKProtoDataMessageGroupCallUpdateBuilder *updateBuilder = [SSKProtoDataMessageGroupCallUpdate builder];
    [updateBuilder setEraID:self.eraId];

    SSKProtoDataMessageGroupCallUpdate *_Nullable updateMessage = [updateBuilder buildAndReturnError:&error];
    if (error || !updateMessage) {
        OWSFailDebug(@"Couldn't build GroupCallUpdate message");
        return nil;
    }

    SSKProtoDataMessageBuilder *builder = [super dataMessageBuilderWithThread:thread transaction:transaction];
    [builder setGroupCallUpdate:updateMessage];
    return builder;
}

- (SealedSenderContentHint)contentHint
{
    return SealedSenderContentHintDefault;
}

@end
