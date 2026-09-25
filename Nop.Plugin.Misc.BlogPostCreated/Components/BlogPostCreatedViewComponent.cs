using Microsoft.AspNetCore.Mvc;
using Nop.Core;
using Nop.Core.Domain.Blogs;
using Nop.Plugin.Misc.BlogPostCreated.Models;
using Nop.Services.Blogs;
using Nop.Services.Common;
using Nop.Services.Configuration;
using Nop.Services.Customers;
using Nop.Services.Stores;
using Nop.Web.Framework.Components;
using Nop.Web.Framework.Mvc.Routing;

namespace Nop.Plugin.Misc.BlogPostCreated.Components;

public class BlogPostCreatedViewComponent : NopViewComponent
{
    private readonly BlogSettings _blogSettings;
    private readonly IBlogService _blogService;
    private readonly ICustomerService _customerService;
    private readonly IGenericAttributeService _genericAttributeService;
    private readonly INopUrlHelper _nopUrlHelper;
    private readonly ISettingService _settingService;
    private readonly IStoreContext _storeContext;
    private readonly IStoreMappingService _storeMappingService;
    private readonly IWorkContext _workContext;

    public BlogPostCreatedViewComponent(BlogSettings blogSettings,
        IBlogService blogService,
        ICustomerService customerService,
        IGenericAttributeService genericAttributeService,
        INopUrlHelper nopUrlHelper,
        ISettingService settingService,
        IStoreContext storeContext,
        IStoreMappingService storeMappingService,
        IWorkContext workContext)
    {
        _blogSettings = blogSettings;
        _blogService = blogService;
        _customerService = customerService;
        _genericAttributeService = genericAttributeService;
        _nopUrlHelper = nopUrlHelper;
        _settingService = settingService;
        _storeContext = storeContext;
        _storeMappingService = storeMappingService;
        _workContext = workContext;
    }

    public async Task<IViewComponentResult> InvokeAsync(string widgetZone, object additionalData)
    {
        var customer = await _workContext.GetCurrentCustomerAsync();
        if (customer == null || !await _customerService.IsRegisteredAsync(customer))
            return Content(string.Empty);

        var lastSeenBlogPostId = await _genericAttributeService.GetAttributeAsync<int>(
            customer,
            BlogPostCreatedDefaults.LastSeenBlogPostIdAttribute);
        var latestBlogPostCreatedId = await _settingService.GetSettingByKeyAsync<int>(
            BlogPostCreatedSettings.LastBlogPostCreatedIdSettingKey);

        if (latestBlogPostCreatedId <= lastSeenBlogPostId)
            return Content(string.Empty);

        var blogPost = await _blogService.GetBlogPostByIdAsync(latestBlogPostCreatedId);
        if (blogPost == null || !_blogSettings.Enabled || !_blogService.BlogPostIsAvailable(blogPost))
            return Content(string.Empty);

        var language = await _workContext.GetWorkingLanguageAsync();
        if (language == null || blogPost.LanguageId != language.Id)
            return Content(string.Empty);

        var store = await _storeContext.GetCurrentStoreAsync();
        if (store == null || !await _storeMappingService.AuthorizeAsync(blogPost, store.Id))
            return Content(string.Empty);

        var url = await _nopUrlHelper.RouteGenericUrlAsync(blogPost,
            languageId: language.Id,
            ensureTwoPublishedLanguages: false);
        if (string.IsNullOrWhiteSpace(url))
            return Content(string.Empty);

        await _genericAttributeService.SaveAttributeAsync(customer,
            BlogPostCreatedDefaults.LastSeenBlogPostIdAttribute,
            latestBlogPostCreatedId);

        return View("~/Plugins/Misc.BlogPostCreated/Views/PublicInfo.cshtml", new BlogPostCreatedPopupModel
        {
            Title = blogPost.Title,
            Url = url
        });
    }
}
