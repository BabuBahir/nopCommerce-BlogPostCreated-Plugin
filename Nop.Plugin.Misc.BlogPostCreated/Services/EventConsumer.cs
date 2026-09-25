using Nop.Core.Domain.Blogs;
using Nop.Core.Events;
using Nop.Services.Configuration;
using Nop.Services.Events;
using Nop.Services.Logging;

namespace Nop.Plugin.Misc.BlogPostCreated.Services;

public class EventConsumer : IConsumer<EntityInsertedEvent<BlogPost>>
{
    private readonly ILogger _logger;
    private readonly ISettingService _settingService;

    public EventConsumer(ILogger logger, ISettingService settingService)
    {
        _logger = logger;
        _settingService = settingService;
    }

    public async Task HandleEventAsync(EntityInsertedEvent<BlogPost> eventMessage)
    {
        if (eventMessage?.Entity == null)
            return;

        await _logger.InformationAsync(
            $"Blog post created. Id: {eventMessage.Entity.Id}, Title: {eventMessage.Entity.Title}, CreatedOnUtc: {eventMessage.Entity.CreatedOnUtc:O}");

        var lastBlogPostCreatedId = await _settingService.GetSettingByKeyAsync<int>(
            BlogPostCreatedSettings.LastBlogPostCreatedIdSettingKey);

        if (eventMessage.Entity.Id <= lastBlogPostCreatedId)
            return;

        await _settingService.SetSettingAsync(
            BlogPostCreatedSettings.LastBlogPostCreatedIdSettingKey,
            eventMessage.Entity.Id);
    }
}
