#include "mediaplayer.h"
#include "qtavplayerutils.h"
#include <QtAVPlayer/qavplayer.h>

QtAVPlayerUtils::QtAVPlayerUtils(QObject *parent) : QObject(parent)
{
}

qint64 QtAVPlayerUtils::displayPosition(QObject *qmlPlayer)
{
    auto player = qmlPlayer->findChild<QAVPlayer*>();
    return player ? player->position() : 0;
}

qreal QtAVPlayerUtils::fps(QObject *qmlPlayer)
{
    auto player = qobject_cast<MediaPlayer*>(qmlPlayer);
    return player ? (player->videoFrameRate() ? 1.0 / player->videoFrameRate() : 0) : 0;
}
