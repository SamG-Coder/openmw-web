#ifndef MWRENDER_SCREENSHOTMANAGER_H
#define MWRENDER_SCREENSHOTMANAGER_H

#include <osg/ref_ptr>
#include <functional>
#include <string>
#include <osg/Image>

#include <osgViewer/Viewer>

namespace MWRender
{
    class NotifyDrawCompletedCallback;

    class ScreenshotManager
    {
    public:
        ScreenshotManager(osgViewer::Viewer* viewer);
        ~ScreenshotManager();

        void screenshot(osg::Image* image, int w, int h);
        void screenshotAsync(int w,int h,std::function<void(osg::ref_ptr<osg::Image>,std::string)> completion);

    private:
        osg::ref_ptr<osgViewer::Viewer> mViewer;
        osg::ref_ptr<NotifyDrawCompletedCallback> mDrawCompleteCallback;
    };
}

#endif
