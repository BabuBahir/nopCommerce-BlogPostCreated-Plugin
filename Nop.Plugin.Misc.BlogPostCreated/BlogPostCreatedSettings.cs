using Nop.Core.Configuration;

namespace Nop.Plugin.Misc.BlogPostCreated;

public class BlogPostCreatedSettings : ISettings
{
    public const string LastBlogPostCreatedIdSettingKey = "BlogPostCreatedSettings.LastBlogPostCreatedId";

    public int LastBlogPostCreatedId { get; set; }
}
