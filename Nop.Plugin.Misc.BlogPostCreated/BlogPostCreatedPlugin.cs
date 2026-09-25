using Nop.Core.Domain.Cms;
using Nop.Core.Domain.Customers;
using Nop.Plugin.Misc.BlogPostCreated.Components;
using Nop.Services.Cms;
using Nop.Services.Common;
using Nop.Services.Configuration;
using Nop.Services.Plugins;
using Nop.Web.Framework.Infrastructure;

namespace Nop.Plugin.Misc.BlogPostCreated;

public class BlogPostCreatedPlugin : BasePlugin, IWidgetPlugin
{
    private readonly IGenericAttributeService _genericAttributeService;
    private readonly ISettingService _settingService;
    private readonly WidgetSettings _widgetSettings;

    public BlogPostCreatedPlugin(IGenericAttributeService genericAttributeService,
        ISettingService settingService,
        WidgetSettings widgetSettings)
    {
        _genericAttributeService = genericAttributeService;
        _settingService = settingService;
        _widgetSettings = widgetSettings;
    }

    public Task<IList<string>> GetWidgetZonesAsync()
    {
        return Task.FromResult<IList<string>>(new List<string> { PublicWidgetZones.Notifications });
    }

    public Type GetWidgetViewComponent(string widgetZone)
    {
        return typeof(BlogPostCreatedViewComponent);
    }

    public override async Task InstallAsync()
    {
        await _settingService.SaveSettingAsync(new BlogPostCreatedSettings());
        await ActivateWidgetAsync();
        await base.InstallAsync();
    }

    public override async Task UpdateAsync(string currentVersion, string targetVersion)
    {
        await ActivateWidgetAsync();
        await base.UpdateAsync(currentVersion, targetVersion);
    }

    public override async Task UninstallAsync()
    {
        if (_widgetSettings.ActiveWidgetSystemNames.Contains(BlogPostCreatedDefaults.SystemName))
        {
            _widgetSettings.ActiveWidgetSystemNames.Remove(BlogPostCreatedDefaults.SystemName);
            await _settingService.SaveSettingAsync(_widgetSettings);
        }

        await _settingService.DeleteSettingAsync<BlogPostCreatedSettings>();
        await _genericAttributeService.DeleteAttributesAsync<Customer>(BlogPostCreatedDefaults.LastSeenBlogPostIdAttribute);
        await base.UninstallAsync();
    }

    public bool HideInWidgetList => false;

    private async Task ActivateWidgetAsync()
    {
        if (_widgetSettings.ActiveWidgetSystemNames.Contains(BlogPostCreatedDefaults.SystemName))
            return;

        _widgetSettings.ActiveWidgetSystemNames.Add(BlogPostCreatedDefaults.SystemName);
        await _settingService.SaveSettingAsync(_widgetSettings);
    }
}
